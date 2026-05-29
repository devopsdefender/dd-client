//! The DevOps Defender client session engine.
//!
//! This crate sits between [`dd_client_core`] (Noise transport, quote
//! verification, RPCs, keys) and the platform frontends (CLI, iOS). It owns the
//! interpretation layer: it consumes the PTY byte stream of an attached session
//! and — in later phases — derives a structured "chat document" (markdown
//! blocks + menus), tracks view modes, and routes input.
//!
//! Phase 0 establishes only the seam: [`transport`] drives the Noise duplex
//! (forward input frames, surface decrypted output frames) with no terminal
//! coupling, so the same loop serves every frontend.

pub mod block;
pub mod derive;
pub mod engine;
pub mod input;
pub mod mode;
pub mod stream;
pub mod transport;

pub use engine::SessionEngine;
pub use mode::ViewMode;
