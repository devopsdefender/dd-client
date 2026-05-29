//! Menu / prompt detection over a screen snapshot.
//!
//! This is the deliberately-fragile floor heuristic the design calls out: from a
//! grid of text + per-row highlight flags, guess whether the app is presenting a
//! selectable list. It recognizes two shapes:
//!   * a run of ≥2 numbered/bulleted option lines, with the selected row marked
//!     by reverse-video or a leading `>`/`❯` arrow;
//!   * a single yes/no prompt (`(y/n)`, `[Y/n]`).
//!
//! Callers gate this on output quiescence (the agent has gone quiet ⇒ likely
//! awaiting input) — see the engine. Per-agent adapters replace this with exact
//! structure for the agents people actually use.

use crate::block::{Menu, MenuOption, MenuState};

use super::screen::ScreenSnapshot;

const ARROW_MARKERS: [char; 5] = ['>', '❯', '➤', '●', '*'];

/// Detect a menu on the current screen, or `None`.
pub fn detect_menu(screen: &ScreenSnapshot) -> Option<Menu> {
    if let Some(menu) = detect_option_list(screen) {
        return Some(menu);
    }
    detect_yes_no(screen)
}

fn detect_option_list(screen: &ScreenSnapshot) -> Option<Menu> {
    let rows = &screen.rows;
    // Find the last (closest-to-bottom) run of ≥2 consecutive option lines.
    let mut best: Option<(usize, usize)> = None;
    let mut i = 0;
    while i < rows.len() {
        if option_label(&rows[i].text).is_some() {
            let start = i;
            while i < rows.len() && option_label(&rows[i].text).is_some() {
                i += 1;
            }
            if i - start >= 2 {
                best = Some((start, i));
            }
        } else {
            i += 1;
        }
    }
    let (start, end) = best?;

    let mut options = Vec::new();
    let mut selected = None;
    for (idx, row) in rows[start..end].iter().enumerate() {
        let (label, hotkey) = option_label(&row.text)?;
        if row.inverse || starts_with_marker(&row.text) {
            selected = Some(idx);
        }
        options.push(MenuOption {
            label,
            hotkey,
            raw_row: (start + idx) as u16,
        });
    }
    Some(Menu {
        title: None,
        options,
        selected,
        state: MenuState::Live,
    })
}

fn detect_yes_no(screen: &ScreenSnapshot) -> Option<Menu> {
    let row = screen
        .rows
        .iter()
        .rev()
        .find(|r| !r.text.trim().is_empty())?;
    let lower = row.text.to_lowercase();
    if !(lower.contains("(y/n)") || lower.contains("[y/n]") || lower.contains("(yes/no)")) {
        return None;
    }
    Some(Menu {
        title: Some(row.text.trim().to_string()),
        options: vec![
            MenuOption {
                label: "Yes".into(),
                hotkey: Some('y'),
                raw_row: 0,
            },
            MenuOption {
                label: "No".into(),
                hotkey: Some('n'),
                raw_row: 0,
            },
        ],
        selected: None,
        state: MenuState::Live,
    })
}

fn starts_with_marker(line: &str) -> bool {
    line.trim_start()
        .starts_with(|c: char| ARROW_MARKERS.contains(&c))
}

/// Parse an option line, returning `(label, hotkey)` if it looks like one.
/// Accepts an optional leading arrow/bullet marker, then either a number
/// (`1.`/`1)`) or a bracketed/lettered hotkey, then the label text.
fn option_label(line: &str) -> Option<(String, Option<char>)> {
    let mut s = line.trim_start();
    // Strip a leading selection marker.
    if let Some(rest) = s.strip_prefix(|c: char| ARROW_MARKERS.contains(&c)) {
        s = rest.trim_start();
    }
    if s.is_empty() {
        return None;
    }

    // Numbered: "1. label" or "1) label".
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !digits.is_empty() {
        let rest = &s[digits.len()..];
        if let Some(label) = rest.strip_prefix(['.', ')']) {
            let label = label.trim();
            if !label.is_empty() {
                let hotkey = digits.chars().next().filter(|_| digits.len() == 1);
                return Some((label.to_string(), hotkey));
            }
        }
    }

    // Bracketed letter: "[a] label" or "(a) label".
    let bytes = s.as_bytes();
    if bytes.len() >= 3 {
        let (open, close) = (bytes[0], bytes[2]);
        let mid = bytes[1] as char;
        if (open == b'[' && close == b']' || open == b'(' && close == b')')
            && mid.is_ascii_alphanumeric()
        {
            let label = s[3..].trim();
            if !label.is_empty() {
                return Some((label.to_string(), Some(mid.to_ascii_lowercase())));
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::derive::screen::RowSnapshot;

    fn screen(rows: &[(&str, bool)]) -> ScreenSnapshot {
        ScreenSnapshot {
            rows: rows
                .iter()
                .map(|(t, inv)| RowSnapshot {
                    text: (*t).to_string(),
                    inverse: *inv,
                })
                .collect(),
            cursor: (0, 0),
            alternate: false,
        }
    }

    #[test]
    fn numbered_list_with_inverse_selection() {
        let s = screen(&[
            ("Choose an option:", false),
            ("1. Apply", false),
            ("2. Skip", true), // highlighted
            ("3. Quit", false),
        ]);
        let menu = detect_menu(&s).expect("menu");
        assert_eq!(menu.options.len(), 3);
        assert_eq!(menu.options[0].label, "Apply");
        assert_eq!(menu.options[0].hotkey, Some('1'));
        assert_eq!(menu.selected, Some(1));
    }

    #[test]
    fn arrow_marker_marks_selection() {
        let s = screen(&[("> 1) yes", false), ("  2) no", false)]);
        let menu = detect_menu(&s).expect("menu");
        assert_eq!(menu.selected, Some(0));
        assert_eq!(menu.options[1].label, "no");
    }

    #[test]
    fn yes_no_prompt() {
        let s = screen(&[("Proceed with deploy? (y/n)", false)]);
        let menu = detect_menu(&s).expect("menu");
        assert_eq!(menu.options.len(), 2);
        assert_eq!(menu.options[0].hotkey, Some('y'));
        assert_eq!(menu.options[1].hotkey, Some('n'));
    }

    #[test]
    fn plain_prose_is_not_a_menu() {
        let s = screen(&[
            ("Here is a paragraph of normal output.", false),
            ("It continues on a second line.", false),
        ]);
        assert!(detect_menu(&s).is_none());
    }

    #[test]
    fn single_option_is_not_enough() {
        let s = screen(&[
            ("intro", false),
            ("1. only one", false),
            ("trailing", false),
        ]);
        assert!(detect_menu(&s).is_none());
    }
}
