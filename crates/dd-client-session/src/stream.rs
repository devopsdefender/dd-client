//! Authoritative block log + delta replay.
//!
//! [`BlockLog`] is the engine's source of truth. Each mutation returns the
//! [`BlockEvent`] it produced so the caller can broadcast it. Consumers keep a
//! [`BlockView`] seeded from a snapshot and replay events onto it — the same
//! logic the FFI/iOS layer will use, so it's defined and tested once here.

use std::collections::HashMap;

use crate::block::{Block, BlockEvent, BlockId, BlockKind, BlockPatch, Revision};

/// The engine-owned, authoritative ordered log of blocks.
#[derive(Default)]
pub struct BlockLog {
    blocks: Vec<(BlockId, Revision, Block)>,
    index: HashMap<BlockId, usize>,
    next_id: u64,
}

impl BlockLog {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a fresh, empty block of `kind`. Returns the new id and the event.
    pub fn append(&mut self, kind: BlockKind) -> (BlockId, BlockEvent) {
        let id = BlockId(self.next_id);
        self.next_id += 1;
        self.index.insert(id, self.blocks.len());
        self.blocks.push((id, Revision(0), Block::empty(kind)));
        (id, BlockEvent::Append { id, kind })
    }

    /// Apply a patch to an existing block, bumping its revision. Returns the
    /// event, or `None` if the id is unknown.
    pub fn patch(&mut self, id: BlockId, patch: BlockPatch) -> Option<BlockEvent> {
        let idx = *self.index.get(&id)?;
        let (_, rev, block) = &mut self.blocks[idx];
        apply_patch(block, &patch);
        rev.0 += 1;
        let rev = *rev;
        Some(BlockEvent::Update { id, rev, patch })
    }

    /// Mark a block complete. Returns the event, or `None` if unknown.
    pub fn finalize(&mut self, id: BlockId) -> Option<BlockEvent> {
        let idx = *self.index.get(&id)?;
        let (_, rev, block) = &mut self.blocks[idx];
        set_complete(block, true);
        rev.0 += 1;
        Some(BlockEvent::Finalize { id, rev: *rev })
    }

    /// Drop `from` and everything after it. Returns the event, or `None` if unknown.
    pub fn truncate(&mut self, from: BlockId) -> Option<BlockEvent> {
        let idx = *self.index.get(&from)?;
        for (id, _, _) in self.blocks.drain(idx..) {
            self.index.remove(&id);
        }
        Some(BlockEvent::Truncate { from })
    }

    /// A point-in-time copy of the rendered blocks, in order.
    pub fn snapshot(&self) -> Vec<Block> {
        self.blocks.iter().map(|(_, _, b)| b.clone()).collect()
    }

    /// The id of the last block, if any (used by the floor to extend it).
    pub fn last_id(&self) -> Option<BlockId> {
        self.blocks.last().map(|(id, _, _)| *id)
    }

    pub fn is_empty(&self) -> bool {
        self.blocks.is_empty()
    }
}

/// A consumer's local mirror, kept current by replaying [`BlockEvent`]s.
#[derive(Default)]
pub struct BlockView {
    blocks: Vec<Block>,
    index: HashMap<BlockId, usize>,
    order: Vec<BlockId>,
}

impl BlockView {
    /// Seed from a snapshot. Subsequent ids must be replayed via [`Self::apply`];
    /// the snapshot path can't know ids, so a fresh view is normally built purely
    /// from the event stream when ids matter. For render-only use, [`Self::blocks`]
    /// is what you draw.
    pub fn from_snapshot(blocks: Vec<Block>) -> Self {
        Self {
            blocks,
            index: HashMap::new(),
            order: Vec::new(),
        }
    }

    pub fn blocks(&self) -> &[Block] {
        &self.blocks
    }

    /// Replay one delta. Unknown ids on update/finalize are ignored (the view may
    /// have been seeded from a snapshot that predates them).
    pub fn apply(&mut self, event: &BlockEvent) {
        match event {
            BlockEvent::Append { id, kind } => {
                self.index.insert(*id, self.blocks.len());
                self.order.push(*id);
                self.blocks.push(Block::empty(*kind));
            }
            BlockEvent::Update { id, patch, .. } => {
                if let Some(&idx) = self.index.get(id) {
                    apply_patch(&mut self.blocks[idx], patch);
                }
            }
            BlockEvent::Finalize { id, .. } => {
                if let Some(&idx) = self.index.get(id) {
                    set_complete(&mut self.blocks[idx], true);
                }
            }
            BlockEvent::Truncate { from } => {
                if let Some(&idx) = self.index.get(from) {
                    for id in self.order.drain(idx..) {
                        self.index.remove(&id);
                    }
                    self.blocks.truncate(idx);
                }
            }
        }
    }
}

fn apply_patch(block: &mut Block, patch: &BlockPatch) {
    match (block, patch) {
        (Block::Markdown { text, .. }, BlockPatch::AppendText(s)) => text.push_str(s),
        (Block::Code { text, .. }, BlockPatch::AppendText(s)) => text.push_str(s),
        (Block::Diff { unified, .. }, BlockPatch::AppendText(s)) => unified.push_str(s),
        (Block::RawTerminal { screen }, BlockPatch::AppendText(s)) => screen.push_str(s),
        (Block::Markdown { text, .. }, BlockPatch::ReplaceText(s)) => *text = s.clone(),
        (Block::Code { text, .. }, BlockPatch::ReplaceText(s)) => *text = s.clone(),
        (Block::Diff { unified, .. }, BlockPatch::ReplaceText(s)) => *unified = s.clone(),
        (Block::RawTerminal { screen }, BlockPatch::ReplaceText(s)) => *screen = s.clone(),
        (Block::Menu(menu), BlockPatch::MenuSelect(i)) => menu.selected = Some(*i),
        (Block::Menu(menu), BlockPatch::MenuResolve(i)) => {
            menu.state = crate::block::MenuState::Resolved { chosen: *i }
        }
        (Block::Input(input), BlockPatch::InputSubmit) => {
            input.state = crate::block::InputState::Submitted
        }
        // Mismatched patch/block kinds are ignored — the producer never emits them.
        _ => {}
    }
}

fn set_complete(block: &mut Block, value: bool) {
    match block {
        Block::Markdown { complete, .. }
        | Block::Code { complete, .. }
        | Block::Diff { complete, .. } => *complete = value,
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_patch_finalize_roundtrips_through_view() {
        let mut log = BlockLog::new();
        let (id, e_append) = log.append(BlockKind::Markdown);
        let e_patch = log
            .patch(id, BlockPatch::AppendText("hello ".into()))
            .unwrap();
        let e_patch2 = log
            .patch(id, BlockPatch::AppendText("world".into()))
            .unwrap();
        let e_final = log.finalize(id).unwrap();

        let mut view = BlockView::default();
        for ev in [&e_append, &e_patch, &e_patch2, &e_final] {
            view.apply(ev);
        }
        assert_eq!(
            view.blocks(),
            &[Block::Markdown {
                text: "hello world".into(),
                complete: true
            }]
        );
        // The authoritative snapshot agrees.
        assert_eq!(log.snapshot(), view.blocks());
    }

    #[test]
    fn truncate_drops_tail_in_both() {
        let mut log = BlockLog::new();
        let (a, ea) = log.append(BlockKind::Markdown);
        let (_b, eb) = log.append(BlockKind::Markdown);
        let (_c, ec) = log.append(BlockKind::Markdown);
        let et = log.truncate(a).unwrap();

        let mut view = BlockView::default();
        for ev in [&ea, &eb, &ec, &et] {
            view.apply(ev);
        }
        assert!(view.blocks().is_empty());
        assert!(log.is_empty());
    }

    #[test]
    fn revision_bumps_on_each_patch() {
        let mut log = BlockLog::new();
        let (id, _) = log.append(BlockKind::Markdown);
        let BlockEvent::Update { rev: r1, .. } =
            log.patch(id, BlockPatch::AppendText("a".into())).unwrap()
        else {
            panic!("expected update");
        };
        let BlockEvent::Update { rev: r2, .. } =
            log.patch(id, BlockPatch::AppendText("b".into())).unwrap()
        else {
            panic!("expected update");
        };
        assert!(r2 > r1);
    }
}
