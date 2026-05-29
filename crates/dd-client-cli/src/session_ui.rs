//! The flippable session UI: Watch ⇄ Interact ⇄ Raw over one live attachment.
//!
//! A single pump task feeds every output frame into the [`SessionEngine`] (and,
//! while in Raw, straight to the tty). The frontend switches *lenses* over that
//! one engine: a ratatui structured view for Watch/Interact, and a real-tty
//! passthrough for Raw. `Tab`/`Shift-Tab` cycle while structured; `Ctrl-]`+`Tab`
//! pops out of Raw. The engine keeps deriving in every mode, so flipping is
//! lossless.
//!
//! NOTE: the multi-regime live flip is wired against the tested engine/chord/mode
//! logic but has not been exercised against a live PTY here.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::anyhow;
use dd_client_core::NoiseConnection;
use dd_client_session::block::Block as SBlock;
use dd_client_session::derive::ClaudeCodeAdapter;
use dd_client_session::input::{ChordParser, RawAction};
use dd_client_session::transport::{self, Outbound};
use dd_client_session::{SessionEngine, ViewMode};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Text};
use ratatui::widgets::{Block as TuiBlock, Borders, Paragraph, Wrap};
use ratatui::Frame;
use tokio::io::AsyncReadExt;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::mpsc;

/// What a regime returns to the orchestrator.
enum Flow {
    Quit,
    SwitchTo(ViewMode),
}

pub async fn run(
    mut conn: NoiseConnection,
    id: &str,
    start: ViewMode,
    adapter: &str,
) -> anyhow::Result<()> {
    let ack = conn
        .call(serde_json::json!({
            "method": "shell.attach_session",
            "id": id,
            "tail": true,
            "readonly": start.is_readonly(),
        }))
        .await?;
    if ack.get("error").is_some() {
        anyhow::bail!("attach failed: {}", serde_json::to_string(&ack)?);
    }

    let engine = match adapter {
        "claude" | "claude-code" => SessionEngine::with_adapter(Box::new(ClaudeCodeAdapter::new())),
        _ => SessionEngine::new(),
    };
    let mode = Arc::new(Mutex::new(start));
    let (in_tx, in_rx) = mpsc::channel::<Outbound>(256);

    // Persistent pump: feed the engine always; mirror to the tty only in Raw.
    let pump_engine = engine.clone();
    let pump_mode = mode.clone();
    let pump = tokio::spawn(async move {
        let mut out = std::io::stdout();
        let r = transport::run(conn, in_rx, |bytes| {
            pump_engine.feed_output(bytes);
            if *pump_mode.lock().expect("mode poisoned") == ViewMode::Raw {
                let _ = out.write_all(bytes);
                let _ = out.flush();
            }
        })
        .await;
        pump_engine.finish();
        r
    });

    let result = loop {
        let current = *mode.lock().expect("mode poisoned");
        let outcome = if current.is_structured() {
            run_structured(&engine, &mode, &in_tx).await
        } else {
            run_raw(&engine, &mode, &in_tx).await
        };
        match outcome {
            Ok(Flow::Quit) => break Ok(()),
            Ok(Flow::SwitchTo(m)) => *mode.lock().expect("mode poisoned") = m,
            Err(e) => break Err(e),
        }
    };

    drop(in_tx);
    let _ = pump.await;
    result
}

// ── Structured regime (Watch / Interact) ───────────────────────────────────

async fn run_structured(
    engine: &SessionEngine,
    mode: &Arc<Mutex<ViewMode>>,
    in_tx: &mpsc::Sender<Outbound>,
) -> anyhow::Result<Flow> {
    let (snapshot, mut rx) = engine.subscribe();

    // Key reader on a blocking thread (poll so it exits promptly on quit).
    let stop = Arc::new(AtomicBool::new(false));
    let (key_tx, mut key_rx) = mpsc::channel::<Event>(64);
    let stop_reader = stop.clone();
    let reader = tokio::task::spawn_blocking(move || loop {
        if stop_reader.load(Ordering::Relaxed) {
            break;
        }
        if let Ok(true) = event::poll(Duration::from_millis(100)) {
            match event::read() {
                Ok(ev) => {
                    if key_tx.blocking_send(ev).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let mut terminal = ratatui::init();
    let mut blocks = snapshot;
    let mut scroll: u16 = 0;
    let mut follow = true;

    let flow = loop {
        let current = *mode.lock().expect("mode poisoned");
        let menu = if current == ViewMode::Interact {
            engine.detect_menu()
        } else {
            None
        };

        if let Err(e) =
            terminal.draw(|f| draw(f, current, &blocks, menu.as_ref(), &mut scroll, follow))
        {
            break Err(e.into());
        }

        tokio::select! {
            ev = async {
                match rx.recv().await {
                    Ok(_) | Err(RecvError::Lagged(_)) => Some(()),
                    Err(RecvError::Closed) => None,
                }
            } => {
                if ev.is_some() {
                    blocks = engine.snapshot();
                } // Closed: pump ended; keep the view until the user quits.
            }
            key = key_rx.recv() => {
                let Some(Event::Key(k)) = key else {
                    if key.is_none() { break Ok(Flow::Quit); }
                    if let Some(Event::Resize(cols, rows)) = key { engine.resize(rows, cols); }
                    continue;
                };
                match classify_structured_key(current, &k) {
                    StructAction::Quit => break Ok(Flow::Quit),
                    StructAction::CycleNext | StructAction::CyclePrev => {
                        let nm = if matches!(classify_structured_key(current, &k), StructAction::CycleNext) {
                            current.next()
                        } else {
                            current.prev()
                        };
                        *mode.lock().expect("mode poisoned") = nm;
                        if !nm.is_structured() {
                            break Ok(Flow::SwitchTo(nm));
                        }
                        // Watch ⇄ Interact: stay in this regime.
                    }
                    StructAction::ScrollUp => { follow = false; scroll = scroll.saturating_sub(1); }
                    StructAction::ScrollDown => scroll = scroll.saturating_add(1),
                    StructAction::PageUp => { follow = false; scroll = scroll.saturating_sub(10); }
                    StructAction::PageDown => scroll = scroll.saturating_add(10),
                    StructAction::Follow => follow = true,
                    StructAction::ForwardKey => {
                        if let Some(bytes) = key_to_bytes(&k) {
                            if in_tx.send(Outbound::Bytes(bytes)).await.is_err() {
                                break Ok(Flow::Quit);
                            }
                        }
                    }
                    StructAction::Ignore => {}
                }
            }
        }
    };

    ratatui::restore();
    stop.store(true, Ordering::Relaxed);
    let _ = reader.await;
    flow
}

enum StructAction {
    Quit,
    CycleNext,
    CyclePrev,
    ScrollUp,
    ScrollDown,
    PageUp,
    PageDown,
    Follow,
    ForwardKey,
    Ignore,
}

fn classify_structured_key(mode: ViewMode, k: &KeyEvent) -> StructAction {
    // Tab/Shift-Tab always cycle (reserved from the app in structured modes).
    match k.code {
        KeyCode::Tab => return StructAction::CycleNext,
        KeyCode::BackTab => return StructAction::CyclePrev,
        KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => {
            return StructAction::Quit
        }
        _ => {}
    }

    match mode {
        ViewMode::Watch => match k.code {
            KeyCode::Char('q') | KeyCode::Esc => StructAction::Quit,
            KeyCode::Up => StructAction::ScrollUp,
            KeyCode::Down => StructAction::ScrollDown,
            KeyCode::PageUp => StructAction::PageUp,
            KeyCode::PageDown => StructAction::PageDown,
            KeyCode::End => StructAction::Follow,
            _ => StructAction::Ignore,
        },
        // Interact forwards keystrokes to the PTY (drive the live menu), except
        // the reserved cycle keys above. PgUp/PgDn still scroll the transcript.
        ViewMode::Interact => match k.code {
            KeyCode::PageUp => StructAction::PageUp,
            KeyCode::PageDown => StructAction::PageDown,
            _ => StructAction::ForwardKey,
        },
        ViewMode::Raw => StructAction::Ignore,
    }
}

// ── Raw regime ──────────────────────────────────────────────────────────────

async fn run_raw(
    engine: &SessionEngine,
    _mode: &Arc<Mutex<ViewMode>>,
    in_tx: &mpsc::Sender<Outbound>,
) -> anyhow::Result<Flow> {
    let _raw = RawMode::enter()?;

    // Repaint the current screen so Raw doesn't start blank.
    {
        let mut out = std::io::stdout();
        let _ = out.write_all(b"\x1b[2J\x1b[H");
        let _ = out.write_all(&engine.screen_formatted());
        let _ = out.flush();
    }
    eprint!("\r\n[RAW] Ctrl-] Tab → structured · Ctrl-] Ctrl-] → detach · Ctrl-D → EOF\r\n");

    let mut chord = ChordParser::new();
    let mut stdin = tokio::io::stdin();
    let mut buf = [0u8; 4096];

    loop {
        let n = match stdin.read(&mut buf).await {
            Ok(0) | Err(_) => return Ok(Flow::Quit),
            Ok(n) => n,
        };
        for action in chord.feed(&buf[..n]) {
            match action {
                RawAction::Forward(bytes) => {
                    if in_tx.send(Outbound::Bytes(bytes)).await.is_err() {
                        return Ok(Flow::Quit);
                    }
                }
                RawAction::ForwardThenStop(bytes) => {
                    let _ = in_tx.send(Outbound::BytesThenStop(bytes)).await;
                    return Ok(Flow::Quit);
                }
                RawAction::ExitToStructured => return Ok(Flow::SwitchTo(ViewMode::Watch)),
                RawAction::Detach => return Ok(Flow::Quit),
            }
        }
    }
}

/// Map a crossterm key to the bytes a PTY expects. Returns `None` for keys with
/// no byte representation (the reserved cycle keys never reach here).
fn key_to_bytes(k: &KeyEvent) -> Option<Vec<u8>> {
    let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
    Some(match k.code {
        KeyCode::Char(c) if ctrl && c.is_ascii_alphabetic() => {
            vec![(c.to_ascii_uppercase() as u8) & 0x1f]
        }
        KeyCode::Char(c) => c.to_string().into_bytes(),
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        _ => return None,
    })
}

// ── Rendering ─────────────────────────────────────────────────────────────

fn draw(
    f: &mut Frame,
    mode: ViewMode,
    blocks: &[SBlock],
    menu: Option<&dd_client_session::block::Menu>,
    scroll: &mut u16,
    follow: bool,
) {
    let area = f.area();
    let menu_h = menu.map(|m| m.options.len() as u16 + 2).unwrap_or(0);
    let rows = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(menu_h),
        Constraint::Length(1),
    ])
    .split(area);
    let body: Rect = rows[0];

    let text = render_blocks(blocks);
    let total = text.lines.len() as u16;
    let inner_h = body.height.saturating_sub(2);
    let max_scroll = total.saturating_sub(inner_h);
    if follow || *scroll > max_scroll {
        *scroll = max_scroll;
    }

    let integrity = if mode.is_readonly() {
        "clean"
    } else {
        "controlled"
    };
    let title = format!(" {} ({integrity}) — {total} lines ", mode.label());
    let para = Paragraph::new(text)
        .wrap(Wrap { trim: false })
        .scroll((*scroll, 0))
        .block(TuiBlock::default().borders(Borders::ALL).title(title));
    f.render_widget(para, body);

    if let Some(menu) = menu {
        f.render_widget(render_menu(menu), rows[1]);
    }

    let hints = match mode {
        ViewMode::Watch => "q quit · ↑/↓ scroll · End follow · Tab→Interact",
        ViewMode::Interact => "keys→session · PgUp/PgDn scroll · Tab→Raw · Shift-Tab→Watch",
        ViewMode::Raw => "",
    };
    let status = Paragraph::new(Line::styled(
        format!(" {hints} "),
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(status, rows[2]);
}

fn render_menu(menu: &dd_client_session::block::Menu) -> Paragraph<'static> {
    let mut lines: Vec<Line> = Vec::new();
    for (i, opt) in menu.options.iter().enumerate() {
        let marker = if menu.selected == Some(i) {
            "❯ "
        } else {
            "  "
        };
        let key = opt
            .hotkey
            .map(|c| format!("{c}. "))
            .unwrap_or_else(|| "  ".to_string());
        let style = if menu.selected == Some(i) {
            Style::default().fg(Color::Black).bg(Color::Cyan)
        } else {
            Style::default().fg(Color::Cyan)
        };
        lines.push(Line::styled(format!("{marker}{key}{}", opt.label), style));
    }
    Paragraph::new(Text::from(lines)).block(
        TuiBlock::default()
            .borders(Borders::ALL)
            .title(" menu (arrows/enter) ")
            .border_style(Style::default().fg(Color::Yellow)),
    )
}

fn render_blocks(blocks: &[SBlock]) -> Text<'static> {
    let mut lines: Vec<Line> = Vec::new();
    for block in blocks {
        match block {
            SBlock::Markdown { text, .. } => {
                for l in text.lines() {
                    lines.push(render_markdown_line(l));
                }
            }
            SBlock::Code { lang, text, .. } => {
                let header = match lang {
                    Some(l) => format!("┌─ code ({l})"),
                    None => "┌─ code".to_string(),
                };
                lines.push(Line::styled(header, Style::default().fg(Color::DarkGray)));
                for l in text.lines() {
                    lines.push(Line::styled(
                        format!("│ {l}"),
                        Style::default().fg(Color::Cyan),
                    ));
                }
            }
            SBlock::Diff { unified, .. } => {
                for l in unified.lines() {
                    let style = match l.as_bytes().first() {
                        Some(b'+') => Style::default().fg(Color::Green),
                        Some(b'-') => Style::default().fg(Color::Red),
                        Some(b'@') => Style::default().fg(Color::Magenta),
                        _ => Style::default().fg(Color::Gray),
                    };
                    lines.push(Line::styled(l.to_string(), style));
                }
            }
            SBlock::RawTerminal { screen } => {
                for l in screen.lines() {
                    lines.push(Line::raw(l.to_string()));
                }
            }
            SBlock::Menu(_) | SBlock::Input(_) => {}
        }
        lines.push(Line::raw(String::new()));
    }
    Text::from(lines)
}

fn render_markdown_line(l: &str) -> Line<'static> {
    let t = l.trim_start();
    if t.starts_with("# ") || t.starts_with("## ") || t.starts_with("### ") {
        Line::styled(
            l.to_string(),
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        Line::raw(l.to_string())
    }
}

struct RawMode {
    #[cfg(unix)]
    original: Option<libc::termios>,
}

impl RawMode {
    fn enter() -> anyhow::Result<Self> {
        #[cfg(unix)]
        {
            if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1 {
                return Ok(Self { original: None });
            }
            let mut original = std::mem::MaybeUninit::<libc::termios>::uninit();
            if unsafe { libc::tcgetattr(libc::STDIN_FILENO, original.as_mut_ptr()) } != 0 {
                return Err(anyhow!("tcgetattr: {}", std::io::Error::last_os_error()));
            }
            let original = unsafe { original.assume_init() };
            let mut raw = original;
            unsafe { libc::cfmakeraw(&mut raw) };
            if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
                return Err(anyhow!(
                    "tcsetattr raw: {}",
                    std::io::Error::last_os_error()
                ));
            }
            Ok(Self {
                original: Some(original),
            })
        }
        #[cfg(not(unix))]
        {
            Ok(Self {})
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(original) = &self.original {
            let _ = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
        }
    }
}
