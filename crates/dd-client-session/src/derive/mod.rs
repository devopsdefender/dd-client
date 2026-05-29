//! Derivation: turning the PTY byte stream into structured blocks.
//!
//! The [`FloorAdapter`] is always present and works for any TUI by interpreting
//! its output. Later phases add per-agent [`Adapter`]s that consume a structured
//! mode (e.g. Claude Code stream-json) for lossless blocks. Both write through a
//! [`BlockSink`], so the engine doesn't care which produced a block.

pub mod claude_code;
pub mod floor;
pub mod menu;
pub mod screen;

use crate::block::{BlockId, BlockKind, BlockPatch};

pub use claude_code::ClaudeCodeAdapter;
pub use floor::FloorAdapter;
pub use screen::{Screen, ScreenSnapshot};

/// Where an adapter pushes block mutations. The engine implements this over its
/// authoritative log + event broadcast.
pub trait BlockSink {
    fn append(&mut self, kind: BlockKind) -> BlockId;
    fn patch(&mut self, id: BlockId, patch: BlockPatch);
    fn finalize(&mut self, id: BlockId);
    fn truncate(&mut self, from: BlockId);
}

/// How faithful an adapter believes its block model is. The engine prefers the
/// highest-confidence adapter; the floor is always [`Confidence::Floor`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Confidence {
    Floor,
    Low,
    Medium,
    High,
}

pub trait Adapter: Send {
    fn name(&self) -> &str;
    /// Feed raw PTY bytes; push any resulting block mutations to `sink`.
    fn feed(&mut self, bytes: &[u8], sink: &mut dyn BlockSink);
    /// Flush any buffered partial line and finalize the open block (called once
    /// the session output ends).
    fn flush(&mut self, sink: &mut dyn BlockSink);
    fn confidence(&self) -> Confidence;
}
