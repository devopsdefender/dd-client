//! The universal floor: a line-oriented interpreter that works for any TUI.
//!
//! It strips ANSI control sequences incrementally (state persists across feed
//! boundaries), splits the output into logical lines, and groups them into
//! `Markdown` / `Code` / `Diff` blocks. A bare carriage return rewrites the
//! current line (the common spinner/progress idiom), which keeps transient
//! redraws out of the block log.
//!
//! Honest limits (Phase 1): output is line-buffered, so a long token-streamed
//! line without newlines appears only once it completes; full-screen
//! (alt-screen) apps that paint absolutely are not modeled here — Phase 2's
//! `vt100` screen handles those and powers menu detection + Raw mode.

use crate::block::{BlockId, BlockKind, BlockPatch};

use super::{Adapter, BlockSink, Confidence};

#[derive(Clone, Copy)]
enum Ansi {
    Normal,
    Esc,
    Csi,
    Osc,
    OscEsc,
}

pub struct FloorAdapter {
    ansi: Ansi,
    line: Vec<u8>,
    /// A carriage return was seen but not yet acted on. `\r\n` is a clean line
    /// ending; a bare `\r` followed by content rewrites the line (spinners).
    pending_cr: bool,
    in_code: bool,
    in_diff: bool,
    current: Option<(BlockId, BlockKind)>,
}

impl Default for FloorAdapter {
    fn default() -> Self {
        Self {
            ansi: Ansi::Normal,
            line: Vec::new(),
            pending_cr: false,
            in_code: false,
            in_diff: false,
            current: None,
        }
    }
}

impl FloorAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Ensure the open block is of `kind`, finalizing a different open block
    /// first. Returns the id to patch.
    fn ensure(&mut self, kind: BlockKind, sink: &mut dyn BlockSink) -> BlockId {
        if let Some((id, k)) = self.current {
            if k == kind {
                return id;
            }
            sink.finalize(id);
        }
        let id = sink.append(kind);
        self.current = Some((id, kind));
        id
    }

    /// If a bare carriage return is pending, the upcoming content rewrites the
    /// line from the start, so clear what we had.
    fn rewrite_if_pending_cr(&mut self) {
        if self.pending_cr {
            self.line.clear();
            self.pending_cr = false;
        }
    }

    fn append_line(&mut self, kind: BlockKind, mut text: String, sink: &mut dyn BlockSink) {
        let id = self.ensure(kind, sink);
        text.push('\n');
        sink.patch(id, BlockPatch::AppendText(text));
    }

    fn emit_line(&mut self, bytes: Vec<u8>, sink: &mut dyn BlockSink) {
        let line = String::from_utf8_lossy(&bytes).into_owned();
        let trimmed = line.trim_start();

        // Fenced code toggles. The fence line itself is not content.
        if trimmed.starts_with("```") {
            if self.in_code {
                self.in_code = false;
                if let Some((id, _)) = self.current.take() {
                    sink.finalize(id);
                }
            } else {
                // Close any open block, then open a code block.
                if let Some((id, _)) = self.current.take() {
                    sink.finalize(id);
                }
                self.in_code = true;
                let id = sink.append(BlockKind::Code);
                self.current = Some((id, BlockKind::Code));
            }
            return;
        }

        if self.in_code {
            self.append_line(BlockKind::Code, line, sink);
            return;
        }

        if !self.in_diff && (trimmed.starts_with("@@ ") || line.starts_with("diff --git ")) {
            self.in_diff = true;
        }
        if self.in_diff {
            if is_diff_line(&line) {
                self.append_line(BlockKind::Diff, line, sink);
                return;
            }
            self.in_diff = false;
            if let Some((id, BlockKind::Diff)) = self.current {
                sink.finalize(id);
                self.current = None;
            }
        }

        self.append_line(BlockKind::Markdown, line, sink);
    }
}

fn is_diff_line(line: &str) -> bool {
    line.starts_with("diff --git")
        || matches!(
            line.as_bytes().first(),
            Some(b'+' | b'-' | b' ' | b'@' | b'\\')
        )
}

impl Adapter for FloorAdapter {
    fn name(&self) -> &str {
        "floor"
    }

    fn feed(&mut self, bytes: &[u8], sink: &mut dyn BlockSink) {
        for &b in bytes {
            self.ansi = match self.ansi {
                Ansi::Normal => match b {
                    0x1b => Ansi::Esc,
                    b'\n' => {
                        self.pending_cr = false;
                        let line = std::mem::take(&mut self.line);
                        self.emit_line(line, sink);
                        Ansi::Normal
                    }
                    b'\r' => {
                        self.pending_cr = true;
                        Ansi::Normal
                    }
                    0x08 => {
                        self.rewrite_if_pending_cr();
                        self.line.pop();
                        Ansi::Normal
                    }
                    b'\t' => {
                        self.rewrite_if_pending_cr();
                        self.line.push(b' ');
                        Ansi::Normal
                    }
                    // Drop other C0 controls; keep printable bytes (incl. UTF-8).
                    0x00..=0x1f => Ansi::Normal,
                    _ => {
                        self.rewrite_if_pending_cr();
                        self.line.push(b);
                        Ansi::Normal
                    }
                },
                Ansi::Esc => match b {
                    b'[' => Ansi::Csi,
                    b']' => Ansi::Osc,
                    _ => Ansi::Normal,
                },
                // CSI ends on a final byte 0x40..=0x7e; params/intermediates continue.
                Ansi::Csi => {
                    if (0x40..=0x7e).contains(&b) {
                        Ansi::Normal
                    } else {
                        Ansi::Csi
                    }
                }
                // OSC ends on BEL or ST (ESC \).
                Ansi::Osc => match b {
                    0x07 => Ansi::Normal,
                    0x1b => Ansi::OscEsc,
                    _ => Ansi::Osc,
                },
                Ansi::OscEsc => Ansi::Normal,
            };
        }
    }

    fn flush(&mut self, sink: &mut dyn BlockSink) {
        if !self.line.is_empty() {
            let line = std::mem::take(&mut self.line);
            self.emit_line(line, sink);
        }
        if let Some((id, _)) = self.current.take() {
            sink.finalize(id);
        }
    }

    fn confidence(&self) -> Confidence {
        Confidence::Floor
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::{Block, BlockEvent};
    use crate::stream::{BlockLog, BlockView};

    /// Test sink backed by a real `BlockLog`, also recording the event stream so
    /// we can assert a `BlockView` reconstructs the same thing.
    #[derive(Default)]
    struct TestSink {
        log: BlockLog,
        events: Vec<BlockEvent>,
    }
    impl BlockSink for TestSink {
        fn append(&mut self, kind: BlockKind) -> BlockId {
            let (id, ev) = self.log.append(kind);
            self.events.push(ev);
            id
        }
        fn patch(&mut self, id: BlockId, patch: BlockPatch) {
            if let Some(ev) = self.log.patch(id, patch) {
                self.events.push(ev);
            }
        }
        fn finalize(&mut self, id: BlockId) {
            if let Some(ev) = self.log.finalize(id) {
                self.events.push(ev);
            }
        }
        fn truncate(&mut self, from: BlockId) {
            if let Some(ev) = self.log.truncate(from) {
                self.events.push(ev);
            }
        }
    }

    fn derive(input: &[u8]) -> TestSink {
        let mut floor = FloorAdapter::new();
        let mut sink = TestSink::default();
        floor.feed(input, &mut sink);
        floor.flush(&mut sink);
        // Sanity: replaying the event stream reconstructs the snapshot.
        let mut view = BlockView::default();
        for ev in &sink.events {
            view.apply(ev);
        }
        assert_eq!(view.blocks(), sink.log.snapshot());
        sink
    }

    #[test]
    fn plain_lines_become_one_markdown_block() {
        let s = derive(b"hello\nworld\n");
        assert_eq!(
            s.log.snapshot(),
            vec![Block::Markdown {
                text: "hello\nworld\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn strips_ansi_color_and_cursor_codes() {
        // Colored "ok" then a cursor-move that should vanish.
        let s = derive(b"\x1b[32mok\x1b[0m\n\x1b[2Kdone\n");
        assert_eq!(
            s.log.snapshot(),
            vec![Block::Markdown {
                text: "ok\ndone\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn crlf_line_endings_are_clean() {
        // Real PTY output uses CRLF; the CR must not wipe the line.
        let s = derive(b"hello\r\nworld\r\n");
        assert_eq!(
            s.log.snapshot(),
            vec![Block::Markdown {
                text: "hello\nworld\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn carriage_return_rewrites_progress_line() {
        // A spinner redrawing the same line; only the final state survives.
        let s = derive(b"working 10%\rworking 80%\rdone\n");
        assert_eq!(
            s.log.snapshot(),
            vec![Block::Markdown {
                text: "done\n".into(),
                complete: true
            }]
        );
    }

    #[test]
    fn fenced_code_becomes_code_block_between_markdown() {
        let s = derive(b"intro\n```rust\nfn main() {}\n```\noutro\n");
        assert_eq!(
            s.log.snapshot(),
            vec![
                Block::Markdown {
                    text: "intro\n".into(),
                    complete: true
                },
                Block::Code {
                    lang: None,
                    text: "fn main() {}\n".into(),
                    complete: true
                },
                Block::Markdown {
                    text: "outro\n".into(),
                    complete: true
                },
            ]
        );
    }

    #[test]
    fn unified_diff_hunk_becomes_diff_block() {
        let input = b"edit:\n@@ -1,2 +1,2 @@\n-old\n+new\n done\nafter\n";
        let s = derive(input);
        assert_eq!(
            s.log.snapshot(),
            vec![
                Block::Markdown {
                    text: "edit:\n".into(),
                    complete: true
                },
                Block::Diff {
                    unified: "@@ -1,2 +1,2 @@\n-old\n+new\n done\n".into(),
                    complete: true
                },
                Block::Markdown {
                    text: "after\n".into(),
                    complete: true
                },
            ]
        );
    }

    #[test]
    fn ansi_sequence_split_across_feeds_is_still_stripped() {
        let mut floor = FloorAdapter::new();
        let mut sink = TestSink::default();
        floor.feed(b"a\x1b[", &mut sink); // escape split mid-sequence
        floor.feed(b"31mb\n", &mut sink);
        floor.flush(&mut sink);
        assert_eq!(
            sink.log.snapshot(),
            vec![Block::Markdown {
                text: "ab\n".into(),
                complete: true
            }]
        );
    }
}
