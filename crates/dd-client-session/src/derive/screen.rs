//! Headless terminal screen, wrapping `vt100`.
//!
//! Two jobs: (1) produce a faithful text snapshot of the current screen for the
//! `RawTerminal` block / Raw-mode rendering, and (2) expose per-row highlight
//! info so menu detection can spot the selected option. The `vt100` crate is
//! kept behind this wrapper so the heuristics never depend on it directly.

use vt100::Parser;

const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RowSnapshot {
    pub text: String,
    /// True if any cell in the row is reverse-video — the strongest signal a TUI
    /// uses to mark a highlighted/selected menu row.
    pub inverse: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScreenSnapshot {
    pub rows: Vec<RowSnapshot>,
    /// (row, col) of the cursor.
    pub cursor: (u16, u16),
    /// Whether the app is on the alternate screen (full-screen TUI).
    pub alternate: bool,
}

impl ScreenSnapshot {
    /// The screen as plain text, trailing blank rows trimmed.
    pub fn plain(&self) -> String {
        let last = self
            .rows
            .iter()
            .rposition(|r| !r.text.trim().is_empty())
            .map(|i| i + 1)
            .unwrap_or(0);
        self.rows[..last]
            .iter()
            .map(|r| r.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub struct Screen {
    parser: Parser,
}

impl Default for Screen {
    fn default() -> Self {
        Self::new(DEFAULT_ROWS, DEFAULT_COLS)
    }
}

impl Screen {
    pub fn new(rows: u16, cols: u16) -> Self {
        Self {
            parser: Parser::new(rows, cols, 0),
        }
    }

    pub fn process(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
    }

    pub fn resize(&mut self, rows: u16, cols: u16) {
        self.parser.set_size(rows, cols);
    }

    /// Escape-sequence bytes that repaint the current screen from scratch —
    /// used to restore the display when entering Raw mode.
    pub fn formatted(&self) -> Vec<u8> {
        self.parser.screen().contents_formatted()
    }

    pub fn snapshot(&self) -> ScreenSnapshot {
        let screen = self.parser.screen();
        let (rows, cols) = screen.size();
        let mut out = Vec::with_capacity(rows as usize);
        for r in 0..rows {
            let mut text = String::new();
            let mut inverse = false;
            for c in 0..cols {
                if let Some(cell) = screen.cell(r, c) {
                    let contents = cell.contents();
                    if contents.is_empty() {
                        text.push(' ');
                    } else {
                        text.push_str(&contents);
                    }
                    if cell.inverse() {
                        inverse = true;
                    }
                }
            }
            out.push(RowSnapshot {
                text: text.trim_end().to_string(),
                inverse,
            });
        }
        ScreenSnapshot {
            rows: out,
            cursor: screen.cursor_position(),
            alternate: screen.alternate_screen(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_plain_text() {
        let mut s = Screen::new(4, 20);
        s.process(b"hello\r\nworld\r\n");
        let snap = s.snapshot();
        assert_eq!(snap.rows[0].text, "hello");
        assert_eq!(snap.rows[1].text, "world");
        assert_eq!(snap.plain(), "hello\nworld");
    }

    #[test]
    fn detects_inverse_row() {
        let mut s = Screen::new(4, 20);
        // Normal line, then a reverse-video line.
        s.process(b"normal\r\n\x1b[7mselected\x1b[0m\r\n");
        let snap = s.snapshot();
        assert!(!snap.rows[0].inverse);
        assert!(snap.rows[1].inverse);
        assert_eq!(snap.rows[1].text, "selected");
    }
}
