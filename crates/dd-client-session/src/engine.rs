//! The session engine: owns the authoritative [`BlockLog`], the floor deriver,
//! and the vt100 [`Screen`], and publishes a [`BlockEvent`] broadcast.
//!
//! The frontend feeds every output frame to [`SessionEngine::feed_output`]; the
//! engine drives both the floor (→ structured blocks) and the screen (→ Raw-mode
//! rendering + menu detection). It is cheaply cloneable (shared state) so the
//! pump task and the renderer can each hold one.

use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

use crate::block::{Block, BlockEvent, BlockId, BlockKind, BlockPatch};
use crate::derive::menu::detect_menu;
use crate::derive::screen::ScreenSnapshot;
use crate::derive::{Adapter, BlockSink, FloorAdapter, Screen};
use crate::stream::BlockLog;

const EVENT_CAPACITY: usize = 4096;

#[derive(Clone)]
pub struct SessionEngine {
    log: Arc<Mutex<BlockLog>>,
    tx: broadcast::Sender<BlockEvent>,
    adapter: Arc<Mutex<Box<dyn Adapter>>>,
    screen: Arc<Mutex<Screen>>,
}

impl Default for SessionEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionEngine {
    /// Engine with the universal floor deriver.
    pub fn new() -> Self {
        Self::with_adapter(Box::new(FloorAdapter::new()))
    }

    /// Engine with a specific structured deriver (e.g. a per-agent adapter). The
    /// vt100 screen always runs alongside for Raw-mode rendering + menu detection.
    pub fn with_adapter(adapter: Box<dyn Adapter>) -> Self {
        let (tx, _) = broadcast::channel(EVENT_CAPACITY);
        Self {
            log: Arc::new(Mutex::new(BlockLog::new())),
            tx,
            adapter: Arc::new(Mutex::new(adapter)),
            screen: Arc::new(Mutex::new(Screen::default())),
        }
    }

    /// Feed one decrypted output frame: drives the structured adapter and the
    /// screen (grid). Called from the transport pump.
    pub fn feed_output(&self, bytes: &[u8]) {
        {
            let mut adapter = self.adapter.lock().expect("adapter poisoned");
            let mut sink = self.sink();
            adapter.feed(bytes, &mut sink);
        }
        self.screen.lock().expect("screen poisoned").process(bytes);
    }

    /// Flush the adapter's buffered state and finalize the open block (once the
    /// session output ends).
    pub fn finish(&self) {
        let mut adapter = self.adapter.lock().expect("adapter poisoned");
        let mut sink = self.sink();
        adapter.flush(&mut sink);
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        self.screen
            .lock()
            .expect("screen poisoned")
            .resize(rows, cols);
    }

    /// Current screen snapshot — for Raw-mode rendering and menu detection.
    pub fn screen_snapshot(&self) -> ScreenSnapshot {
        self.screen.lock().expect("screen poisoned").snapshot()
    }

    /// Repaint bytes for the current screen — written to the tty on Raw entry.
    pub fn screen_formatted(&self) -> Vec<u8> {
        self.screen.lock().expect("screen poisoned").formatted()
    }

    /// Detect a menu on the current screen, if any (Interact mode).
    pub fn detect_menu(&self) -> Option<crate::block::Menu> {
        detect_menu(&self.screen_snapshot())
    }

    /// A consistent snapshot plus a receiver for subsequent deltas. The lock is
    /// held across `subscribe()` + `snapshot()` so no event slips between them.
    pub fn subscribe(&self) -> (Vec<Block>, broadcast::Receiver<BlockEvent>) {
        let log = self.log.lock().expect("block log poisoned");
        let rx = self.tx.subscribe();
        let snap = log.snapshot();
        (snap, rx)
    }

    /// Current blocks — used by a renderer to resync after a broadcast lag.
    pub fn snapshot(&self) -> Vec<Block> {
        self.log.lock().expect("block log poisoned").snapshot()
    }

    fn sink(&self) -> EngineSink {
        EngineSink {
            log: self.log.clone(),
            tx: self.tx.clone(),
        }
    }
}

/// A [`BlockSink`] that mutates the engine's log and broadcasts each delta. The
/// log lock is held across the broadcast so [`SessionEngine::subscribe`] stays
/// race-free.
struct EngineSink {
    log: Arc<Mutex<BlockLog>>,
    tx: broadcast::Sender<BlockEvent>,
}

impl BlockSink for EngineSink {
    fn append(&mut self, kind: BlockKind) -> BlockId {
        let mut log = self.log.lock().expect("block log poisoned");
        let (id, ev) = log.append(kind);
        let _ = self.tx.send(ev);
        id
    }

    fn patch(&mut self, id: BlockId, patch: BlockPatch) {
        let mut log = self.log.lock().expect("block log poisoned");
        if let Some(ev) = log.patch(id, patch) {
            let _ = self.tx.send(ev);
        }
    }

    fn finalize(&mut self, id: BlockId) {
        let mut log = self.log.lock().expect("block log poisoned");
        if let Some(ev) = log.finalize(id) {
            let _ = self.tx.send(ev);
        }
    }

    fn truncate(&mut self, from: BlockId) {
        let mut log = self.log.lock().expect("block log poisoned");
        if let Some(ev) = log.truncate(from) {
            let _ = self.tx.send(ev);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn feed_output_lands_in_log_screen_and_broadcasts() {
        let engine = SessionEngine::new();
        let (snap0, mut rx) = engine.subscribe();
        assert!(snap0.is_empty());

        engine.feed_output(b"hello\r\n");
        engine.finish();

        assert!(matches!(rx.try_recv(), Ok(BlockEvent::Append { .. })));
        assert_eq!(
            engine.snapshot(),
            vec![Block::Markdown {
                text: "hello\n".into(),
                complete: true
            }]
        );
        assert_eq!(engine.screen_snapshot().rows[0].text, "hello");
    }

    #[tokio::test]
    async fn menu_detected_from_screen() {
        let engine = SessionEngine::new();
        engine.feed_output(b"Pick:\r\n1. apply\r\n\x1b[7m2. skip\x1b[0m\r\n");
        let menu = engine.detect_menu().expect("menu");
        assert_eq!(menu.options.len(), 2);
        assert_eq!(menu.selected, Some(1));
    }
}
