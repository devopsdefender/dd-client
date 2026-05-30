//! View-mode state machine and its mapping onto the server integrity model.
//!
//! The three modes are projections of one live session. Watch is read-only
//! (transmits nothing → `Clean`); Interact and Raw can send input (`Controlled`).
//! Tab cycles forward, Shift-Tab back; the indicator and the taint badge are the
//! same thing.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ViewMode {
    /// Read-only structured render. Transmits nothing.
    Watch,
    /// Structured render with live menus/input.
    Interact,
    /// Full PTY passthrough.
    Raw,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Integrity {
    Clean,
    Controlled,
}

impl ViewMode {
    pub fn next(self) -> Self {
        match self {
            ViewMode::Watch => ViewMode::Interact,
            ViewMode::Interact => ViewMode::Raw,
            ViewMode::Raw => ViewMode::Watch,
        }
    }

    pub fn prev(self) -> Self {
        match self {
            ViewMode::Watch => ViewMode::Raw,
            ViewMode::Interact => ViewMode::Watch,
            ViewMode::Raw => ViewMode::Interact,
        }
    }

    /// Whether this mode is allowed to transmit input/signals.
    pub fn is_readonly(self) -> bool {
        matches!(self, ViewMode::Watch)
    }

    /// Whether this mode renders structured blocks (vs. raw passthrough).
    pub fn is_structured(self) -> bool {
        !matches!(self, ViewMode::Raw)
    }

    pub fn integrity(self) -> Integrity {
        if self.is_readonly() {
            Integrity::Clean
        } else {
            Integrity::Controlled
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ViewMode::Watch => "WATCH",
            ViewMode::Interact => "INTERACT",
            ViewMode::Raw => "RAW",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cycles_forward_and_back() {
        assert_eq!(ViewMode::Watch.next(), ViewMode::Interact);
        assert_eq!(ViewMode::Interact.next(), ViewMode::Raw);
        assert_eq!(ViewMode::Raw.next(), ViewMode::Watch);
        assert_eq!(ViewMode::Watch.prev(), ViewMode::Raw);
        assert_eq!(ViewMode::Raw.prev(), ViewMode::Interact);
    }

    #[test]
    fn only_watch_is_clean_and_readonly() {
        assert!(ViewMode::Watch.is_readonly());
        assert_eq!(ViewMode::Watch.integrity(), Integrity::Clean);
        for m in [ViewMode::Interact, ViewMode::Raw] {
            assert!(!m.is_readonly());
            assert_eq!(m.integrity(), Integrity::Controlled);
        }
    }

    #[test]
    fn raw_is_the_only_unstructured_mode() {
        assert!(ViewMode::Watch.is_structured());
        assert!(ViewMode::Interact.is_structured());
        assert!(!ViewMode::Raw.is_structured());
    }
}
