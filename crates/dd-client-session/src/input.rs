//! Raw-mode escape chord parsing and menu keystroke synthesis.
//!
//! In Raw mode the app owns `Tab`, so we can't use it to leave. Instead `Ctrl-]`
//! is a prefix: `Ctrl-] Tab` pops back to the structured view, `Ctrl-] Ctrl-]`
//! or `Ctrl-] d` detaches (keeps the remote session alive). `Ctrl-D` still sends
//! EOF and disconnects. Everything else is forwarded verbatim.
//!
//! For menu selection there is no structured channel to a TUI — it awaits a
//! keypress — so a pick is replayed as keystrokes: the option's hotkey when
//! known, otherwise arrow-stepping from the last-observed selection plus Enter.

use crate::block::MenuOption;

pub const CTRL_RIGHT_BRACKET: u8 = 0x1d;
pub const CTRL_D: u8 = 0x04;
const TAB: u8 = 0x09;

/// What the Raw-mode chord parser decided for a span of input.
#[derive(Debug, PartialEq, Eq)]
pub enum RawAction {
    /// Forward these bytes to the PTY.
    Forward(Vec<u8>),
    /// Forward these bytes, then disconnect (EOF).
    ForwardThenStop(Vec<u8>),
    /// Leave Raw, return to the structured view (session stays attached).
    ExitToStructured,
    /// Detach: stop the client but keep the remote session alive.
    Detach,
}

/// Stateful chord parser: `Ctrl-]` may arrive at the end of one read and its
/// continuation at the start of the next, so the "armed" flag persists.
#[derive(Default)]
pub struct ChordParser {
    armed: bool,
}

impl ChordParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Vec<RawAction> {
        let mut actions = Vec::new();
        let mut pending: Vec<u8> = Vec::new();

        for &b in bytes {
            if self.armed {
                self.armed = false;
                match b {
                    TAB => {
                        flush(&mut pending, &mut actions);
                        actions.push(RawAction::ExitToStructured);
                    }
                    CTRL_RIGHT_BRACKET | b'd' => {
                        flush(&mut pending, &mut actions);
                        actions.push(RawAction::Detach);
                    }
                    // Not a chord: the swallowed Ctrl-] was literal input.
                    _ => {
                        pending.push(CTRL_RIGHT_BRACKET);
                        self.consume_plain(b, &mut pending, &mut actions);
                    }
                }
            } else {
                self.consume_plain(b, &mut pending, &mut actions);
            }
        }
        flush(&mut pending, &mut actions);
        actions
    }

    fn consume_plain(&mut self, b: u8, pending: &mut Vec<u8>, actions: &mut Vec<RawAction>) {
        match b {
            CTRL_RIGHT_BRACKET => self.armed = true,
            CTRL_D => {
                flush(pending, actions);
                actions.push(RawAction::ForwardThenStop(vec![CTRL_D]));
            }
            _ => pending.push(b),
        }
    }
}

fn flush(pending: &mut Vec<u8>, actions: &mut Vec<RawAction>) {
    if !pending.is_empty() {
        actions.push(RawAction::Forward(std::mem::take(pending)));
    }
}

/// Synthesize the keystrokes that select `target` in a menu, given the
/// last-observed highlighted index. Prefers the option's hotkey (absolute,
/// avoids stale-cursor drift); otherwise arrow-steps and confirms with Enter.
pub fn menu_select_keys(current: Option<usize>, target: usize, option: &MenuOption) -> Vec<u8> {
    if let Some(c) = option.hotkey {
        // Hotkey selection (numbered/lettered/yes-no) acts on the keypress.
        return vec![c as u8];
    }
    let cur = current.unwrap_or(0);
    let (seq, count): (&[u8], usize) = if target >= cur {
        (b"\x1b[B", target - cur) // Down
    } else {
        (b"\x1b[A", cur - target) // Up
    };
    let mut keys = Vec::with_capacity(seq.len() * count + 1);
    for _ in 0..count {
        keys.extend_from_slice(seq);
    }
    keys.push(b'\r');
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opt(hotkey: Option<char>) -> MenuOption {
        MenuOption {
            label: "x".into(),
            hotkey,
            raw_row: 0,
        }
    }

    #[test]
    fn forwards_plain_bytes() {
        let mut p = ChordParser::new();
        assert_eq!(p.feed(b"ls\n"), vec![RawAction::Forward(b"ls\n".to_vec())]);
    }

    #[test]
    fn ctrl_rbracket_then_tab_exits() {
        let mut p = ChordParser::new();
        assert_eq!(
            p.feed(&[CTRL_RIGHT_BRACKET, TAB]),
            vec![RawAction::ExitToStructured]
        );
    }

    #[test]
    fn double_ctrl_rbracket_detaches() {
        let mut p = ChordParser::new();
        assert_eq!(
            p.feed(&[CTRL_RIGHT_BRACKET, CTRL_RIGHT_BRACKET]),
            vec![RawAction::Detach]
        );
    }

    #[test]
    fn ctrl_d_forwards_then_stops() {
        let mut p = ChordParser::new();
        assert_eq!(
            p.feed(&[CTRL_D]),
            vec![RawAction::ForwardThenStop(vec![CTRL_D])]
        );
    }

    #[test]
    fn chord_split_across_feeds() {
        let mut p = ChordParser::new();
        assert_eq!(p.feed(&[CTRL_RIGHT_BRACKET]), vec![]); // armed, nothing yet
        assert_eq!(p.feed(&[TAB]), vec![RawAction::ExitToStructured]);
    }

    #[test]
    fn ctrl_rbracket_then_other_is_literal() {
        let mut p = ChordParser::new();
        // Ctrl-] then 'x' was not a chord: forward both.
        assert_eq!(
            p.feed(&[CTRL_RIGHT_BRACKET, b'x']),
            vec![RawAction::Forward(vec![CTRL_RIGHT_BRACKET, b'x'])]
        );
    }

    #[test]
    fn hotkey_selection_is_absolute() {
        assert_eq!(menu_select_keys(Some(0), 2, &opt(Some('3'))), vec![b'3']);
    }

    #[test]
    fn arrow_selection_steps_down_then_enter() {
        // From row 0 to row 2: Down, Down, Enter.
        assert_eq!(
            menu_select_keys(Some(0), 2, &opt(None)),
            b"\x1b[B\x1b[B\r".to_vec()
        );
    }

    #[test]
    fn arrow_selection_steps_up() {
        assert_eq!(
            menu_select_keys(Some(3), 1, &opt(None)),
            b"\x1b[A\x1b[A\r".to_vec()
        );
    }
}
