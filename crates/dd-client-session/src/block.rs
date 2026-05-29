//! The structured "chat document" model.
//!
//! A session is rendered as an ordered list of typed [`Block`]s. The engine
//! holds the authoritative log (see [`crate::stream`]) and publishes
//! [`BlockEvent`] deltas; frontends either replay deltas onto their own copy or
//! re-read a snapshot. Phase 1 only populates `Markdown`/`Code`/`Diff` (and a
//! trailing `RawTerminal`); `Menu`/`Input` are defined here but produced later.

/// Engine-assigned, monotonically increasing block identifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BlockId(pub u64);

/// Bumps on every edit to a block, so a consumer can detect missed updates.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Revision(pub u64);

/// One rendered element of the chat document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Block {
    Markdown {
        text: String,
        complete: bool,
    },
    Code {
        lang: Option<String>,
        text: String,
        complete: bool,
    },
    Diff {
        unified: String,
        complete: bool,
    },
    Menu(Menu),
    Input(InputPrompt),
    /// The raw terminal screen — the always-available source of truth. Phase 1
    /// carries plain text; Phase 2 upgrades this to a styled grid snapshot.
    RawTerminal {
        screen: String,
    },
}

/// The variant tag, used by [`BlockEvent::Append`] so a consumer can allocate an
/// empty block of the right kind before patches arrive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockKind {
    Markdown,
    Code,
    Diff,
    Menu,
    Input,
    RawTerminal,
}

impl Block {
    pub fn kind(&self) -> BlockKind {
        match self {
            Block::Markdown { .. } => BlockKind::Markdown,
            Block::Code { .. } => BlockKind::Code,
            Block::Diff { .. } => BlockKind::Diff,
            Block::Menu(_) => BlockKind::Menu,
            Block::Input(_) => BlockKind::Input,
            Block::RawTerminal { .. } => BlockKind::RawTerminal,
        }
    }

    /// An empty block of the given kind, as materialized on [`BlockEvent::Append`].
    pub fn empty(kind: BlockKind) -> Block {
        match kind {
            BlockKind::Markdown => Block::Markdown {
                text: String::new(),
                complete: false,
            },
            BlockKind::Code => Block::Code {
                lang: None,
                text: String::new(),
                complete: false,
            },
            BlockKind::Diff => Block::Diff {
                unified: String::new(),
                complete: false,
            },
            BlockKind::Menu => Block::Menu(Menu::default()),
            BlockKind::Input => Block::Input(InputPrompt::default()),
            BlockKind::RawTerminal => Block::RawTerminal {
                screen: String::new(),
            },
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Menu {
    pub title: Option<String>,
    pub options: Vec<MenuOption>,
    /// Highlighted row as last observed on screen.
    pub selected: Option<usize>,
    pub state: MenuState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuOption {
    pub label: String,
    pub hotkey: Option<char>,
    /// Source screen row, used by keystroke synthesis in Phase 2.
    pub raw_row: u16,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MenuState {
    #[default]
    Live,
    Resolved {
        chosen: usize,
    },
    Stale,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InputPrompt {
    pub prompt: String,
    pub kind: InputKind,
    pub state: InputState,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum InputKind {
    #[default]
    FreeForm,
    Text,
    Password,
    YesNo,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum InputState {
    #[default]
    Awaiting,
    Submitted,
}

/// A delta published when the authoritative log changes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BlockEvent {
    /// A new block began.
    Append { id: BlockId, kind: BlockKind },
    /// An existing block changed.
    Update {
        id: BlockId,
        rev: Revision,
        patch: BlockPatch,
    },
    /// A block is complete; no more edits.
    Finalize { id: BlockId, rev: Revision },
    /// Blocks from `from` onward were invalidated (e.g. an alt-screen clear).
    Truncate { from: BlockId },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BlockPatch {
    AppendText(String),
    ReplaceText(String),
    MenuSelect(usize),
    MenuResolve(usize),
    InputSubmit,
}
