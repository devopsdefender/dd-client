//! UniFFI bindings: one Rust surface, Swift + Kotlin generated from it.
//!
//! The companion app is a thin renderer over `dd-client-session`. All
//! interpretation (blocks, modes, attestation, history) stays here in Rust; the
//! foreign side gets a snapshot of typed blocks and a change callback, and sends
//! input / switches mode. No protocol or crypto logic crosses into Swift.
//!
//! Everything is synchronous across the FFI (a shared multi-thread tokio runtime
//! does the async work internally), so Swift never has to bridge Rust futures.
//!
//! NOTE: this crate is compile-verified on Linux. The generated Swift bindings
//! and the iOS app are built with the Apple toolchain (`uniffi-bindgen generate
//! --library <cdylib> --language swift`), which isn't available in this
//! environment — see apps/ios.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use dd_client_core::{connect, ConnectionOptions, IntelTrustAuthority, QuoteVerification};
use dd_client_session::block::{Block, MenuState as SMenuState};
use dd_client_session::transport::{self, Outbound};
use dd_client_session::{SessionEngine, ViewMode};
use tokio::runtime::Runtime;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

uniffi::setup_scaffolding!();

/// Shared multi-thread runtime: connect handshakes block on it, the pump and the
/// observer-drain run on it.
fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("build tokio runtime")
    })
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{0}")]
    Message(String),
}

fn err(e: impl std::fmt::Display) -> FfiError {
    FfiError::Message(e.to_string())
}

#[derive(uniffi::Record)]
pub struct KeygenResult {
    pub pubkey_hex: String,
    pub enrollment_url: Option<String>,
}

/// Generate (or load) the device key and return its pubkey, plus the CP
/// enrollment URL when `cp_url` + `label` are given.
#[uniffi::export]
pub fn keygen(
    key_path: String,
    cp_url: Option<String>,
    label: Option<String>,
) -> Result<KeygenResult, FfiError> {
    let pubkey_hex = rt()
        .block_on(dd_client_core::public_key_hex(Path::new(&key_path)))
        .map_err(err)?;
    let enrollment_url = match (cp_url.as_deref(), label.as_deref()) {
        (Some(cp), Some(l)) => Some(dd_client_core::enrollment_url(cp, &pubkey_hex, l)),
        _ => None,
    };
    Ok(KeygenResult {
        pubkey_hex,
        enrollment_url,
    })
}

#[derive(Clone, Copy, uniffi::Enum)]
pub enum FfiMode {
    Watch,
    Interact,
    Raw,
}

impl From<FfiMode> for ViewMode {
    fn from(m: FfiMode) -> Self {
        match m {
            FfiMode::Watch => ViewMode::Watch,
            FfiMode::Interact => ViewMode::Interact,
            FfiMode::Raw => ViewMode::Raw,
        }
    }
}
impl From<ViewMode> for FfiMode {
    fn from(m: ViewMode) -> Self {
        match m {
            ViewMode::Watch => FfiMode::Watch,
            ViewMode::Interact => FfiMode::Interact,
            ViewMode::Raw => FfiMode::Raw,
        }
    }
}

#[derive(uniffi::Record)]
pub struct FfiMenuOption {
    pub label: String,
    pub hotkey: Option<String>,
}

#[derive(uniffi::Enum)]
pub enum FfiBlock {
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
    Menu {
        title: Option<String>,
        options: Vec<FfiMenuOption>,
        selected: Option<u32>,
        resolved: bool,
    },
    Input {
        prompt: String,
    },
    RawTerminal {
        screen: String,
    },
}

impl From<&Block> for FfiBlock {
    fn from(b: &Block) -> Self {
        match b {
            Block::Markdown { text, complete } => FfiBlock::Markdown {
                text: text.clone(),
                complete: *complete,
            },
            Block::Code {
                lang,
                text,
                complete,
            } => FfiBlock::Code {
                lang: lang.clone(),
                text: text.clone(),
                complete: *complete,
            },
            Block::Diff { unified, complete } => FfiBlock::Diff {
                unified: unified.clone(),
                complete: *complete,
            },
            Block::Menu(menu) => FfiBlock::Menu {
                title: menu.title.clone(),
                options: menu
                    .options
                    .iter()
                    .map(|o| FfiMenuOption {
                        label: o.label.clone(),
                        hotkey: o.hotkey.map(|c| c.to_string()),
                    })
                    .collect(),
                selected: menu.selected.map(|s| s as u32),
                resolved: matches!(menu.state, SMenuState::Resolved { .. }),
            },
            Block::Input(input) => FfiBlock::Input {
                prompt: input.prompt.clone(),
            },
            Block::RawTerminal { screen } => FfiBlock::RawTerminal {
                screen: screen.clone(),
            },
        }
    }
}

/// Foreign-implemented: called whenever the block document changes. The app
/// re-reads [`SessionHandle::blocks`] and re-renders.
#[uniffi::export(callback_interface)]
pub trait BlockObserver: Send + Sync {
    fn on_changed(&self);
}

/// A live attached session. Holds the engine + the pump driving it; the foreign
/// side renders [`Self::blocks`] and reacts to a [`BlockObserver`].
#[derive(uniffi::Object)]
pub struct SessionHandle {
    engine: SessionEngine,
    input: mpsc::Sender<Outbound>,
    mode: Mutex<ViewMode>,
    pump: Mutex<Option<JoinHandle<()>>>,
    drain: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export]
impl SessionHandle {
    /// Connect to `agent_url`, attach to `session_id` (read-only posture), and
    /// start deriving blocks. Verifies the agent's served ITA token against the
    /// public JWKS unless `insecure_skip_quote_verify`.
    #[uniffi::constructor]
    pub fn attach(
        agent_url: String,
        key_path: String,
        session_id: String,
        insecure_skip_quote_verify: bool,
        jwks_url: String,
        issuer: String,
    ) -> Result<std::sync::Arc<Self>, FfiError> {
        let quote_verification = if insecure_skip_quote_verify {
            QuoteVerification::InsecureSkip
        } else {
            QuoteVerification::IntelTrustAuthority(IntelTrustAuthority {
                jwks_url,
                issuer,
                // Measurement pinning on mobile is a follow-up (needs a trusted
                // pin source); unpinned for now (warns, still verifies genuineness).
                expected_mrtds: Vec::new(),
                expected_tcb: None,
            })
        };
        let opts = ConnectionOptions {
            agent_url,
            key_path: key_path.into(),
            quote_verification,
        };
        rt().block_on(async move {
            let mut conn = connect(&opts).await.map_err(err)?;
            let ack = conn
                .call(serde_json::json!({
                    "method": "shell.attach_session",
                    "id": session_id,
                    "tail": true,
                    "readonly": true,
                }))
                .await
                .map_err(err)?;
            if ack.get("error").is_some() {
                return Err(FfiError::Message(format!("attach failed: {ack}")));
            }
            let engine = SessionEngine::new();
            let (input, in_rx) = mpsc::channel::<Outbound>(256);
            let pump_engine = engine.clone();
            let pump = rt().spawn(async move {
                let _ = transport::run(conn, in_rx, |bytes| pump_engine.feed_output(bytes)).await;
                pump_engine.finish();
            });
            Ok(std::sync::Arc::new(SessionHandle {
                engine,
                input,
                mode: Mutex::new(ViewMode::Watch),
                pump: Mutex::new(Some(pump)),
                drain: Mutex::new(None),
            }))
        })
    }

    /// Current block document.
    pub fn blocks(&self) -> Vec<FfiBlock> {
        self.engine.snapshot().iter().map(FfiBlock::from).collect()
    }

    /// Register a change observer. Replaces any previous one.
    pub fn subscribe(&self, observer: Box<dyn BlockObserver>) {
        let (_snapshot, mut rx) = self.engine.subscribe();
        let handle = rt().spawn(async move {
            // Exits when the broadcast closes (Err(Closed) doesn't match).
            while let Ok(_) | Err(RecvError::Lagged(_)) = rx.recv().await {
                observer.on_changed();
            }
        });
        if let Some(old) = self.drain.lock().expect("drain lock").replace(handle) {
            old.abort();
        }
    }

    /// Send text to the session (dropped in Watch — read-only).
    pub fn send_text(&self, text: String) {
        if *self.mode.lock().expect("mode lock") == ViewMode::Watch {
            return;
        }
        let _ = self.input.try_send(Outbound::Bytes(text.into_bytes()));
    }

    pub fn mode(&self) -> FfiMode {
        (*self.mode.lock().expect("mode lock")).into()
    }

    pub fn set_mode(&self, mode: FfiMode) {
        *self.mode.lock().expect("mode lock") = mode.into();
    }

    /// Stop the session (the remote session stays alive — this just detaches).
    pub fn close(&self) {
        if let Some(h) = self.drain.lock().expect("drain lock").take() {
            h.abort();
        }
        if let Some(h) = self.pump.lock().expect("pump lock").take() {
            h.abort();
        }
    }
}

impl Drop for SessionHandle {
    fn drop(&mut self) {
        if let Some(h) = self.drain.get_mut().expect("drain lock").take() {
            h.abort();
        }
        if let Some(h) = self.pump.get_mut().expect("pump lock").take() {
            h.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keygen_returns_pubkey_and_enrollment_url() {
        let dir = tempfile::tempdir().unwrap();
        let key = dir.path().join("noise.key").to_string_lossy().into_owned();
        let out = keygen(
            key,
            Some("https://cp.example.com".into()),
            Some("ios phone".into()),
        )
        .unwrap();
        assert_eq!(out.pubkey_hex.len(), 64);
        assert_eq!(
            out.enrollment_url.unwrap(),
            format!(
                "https://cp.example.com/admin/enroll?pubkey={}&label=ios%20phone",
                out.pubkey_hex
            )
        );
    }

    #[test]
    fn keygen_without_cp_has_no_url() {
        let dir = tempfile::tempdir().unwrap();
        let key = dir.path().join("k.key").to_string_lossy().into_owned();
        let out = keygen(key, None, None).unwrap();
        assert_eq!(out.pubkey_hex.len(), 64);
        assert!(out.enrollment_url.is_none());
    }

    #[test]
    fn ffi_block_maps_from_session_block() {
        let b = Block::Markdown {
            text: "hi".into(),
            complete: true,
        };
        match FfiBlock::from(&b) {
            FfiBlock::Markdown { text, complete } => {
                assert_eq!(text, "hi");
                assert!(complete);
            }
            _ => panic!("wrong variant"),
        }
    }
}
