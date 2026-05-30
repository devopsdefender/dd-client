//! Drives the Noise duplex for an attached session.
//!
//! Forwards plaintext input frames toward the peer and hands each decrypted
//! output frame to a sink callback, until the input side closes, a [`Outbound::Stop`]
//! is received, or the socket ends. This is deliberately platform-agnostic — no
//! termios, no stdin/stdout. The frontend owns terminal I/O and feeds this loop
//! over an [`mpsc`] channel; the engine (later phases) will sit on top, deriving
//! blocks from the output frames.

use dd_client_core::NoiseConnection;
use tokio::sync::mpsc;

/// A message the frontend sends toward the attached session.
#[derive(Debug)]
pub enum Outbound {
    /// Plaintext bytes to encrypt and forward to the peer (e.g. keystrokes).
    Bytes(Vec<u8>),
    /// Forward these bytes, then stop the loop (e.g. EOF + disconnect).
    BytesThenStop(Vec<u8>),
    /// Stop the loop without sending anything (e.g. detach).
    Stop,
}

/// Run the duplex pump. `on_output` is invoked with each decrypted inbound
/// frame, in order. Returns when input closes, a [`Outbound::Stop`] arrives, or
/// the socket closes.
///
/// `on_output` is synchronous by design: a raw-terminal frontend writes the
/// bytes straight to its tty inside the callback. Higher layers pass a callback
/// that feeds the derivation engine.
pub async fn run<F>(
    conn: NoiseConnection,
    mut input: mpsc::Receiver<Outbound>,
    mut on_output: F,
) -> anyhow::Result<()>
where
    F: FnMut(&[u8]) + Send,
{
    let (mut writer, mut reader) = conn.split();
    loop {
        tokio::select! {
            msg = input.recv() => {
                match msg {
                    None | Some(Outbound::Stop) => break,
                    Some(Outbound::Bytes(b)) => writer.send(&b).await?,
                    Some(Outbound::BytesThenStop(b)) => {
                        writer.send(&b).await?;
                        break;
                    }
                }
            }
            frame = reader.recv() => {
                match frame? {
                    None => break,
                    Some(plain) => on_output(&plain),
                }
            }
        }
    }
    Ok(())
}
