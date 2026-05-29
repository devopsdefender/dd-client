//! Client-side decryption of end-to-end-encrypted session history.
//!
//! `dd-sessiond` seals each transcript record to the paired device pubkeys and
//! `replay` returns the sealed lines — the enclave cannot read them back. This
//! module is the matching opener: with the device's X25519 secret, recover the
//! content key from whichever recipient stanza is ours, decrypt the record, and
//! reconstruct the terminal byte stream.
//!
//! Wire format (must match `dd/src/sessiond.rs::seal_record`): one compact-JSON
//! line per record —
//! ```json
//! {"v":2,"rcpts":[{"epk":"<hex32>","n":"<hex12>","wk":"<b64>"}],"bn":"<hex12>","body":"<b64>"}
//! ```
//! `body` = ChaCha20Poly1305(CEK, bn, serde(TranscriptRecord)); each stanza wraps
//! CEK to one device via ephemeral X25519 + HKDF-SHA256(info =
//! "dd-sessiond-e2e-v2" ‖ epk ‖ recipient_pubkey).

use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use serde::Deserialize;
use serde_json::Value;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

const KDF_INFO_PREFIX: &[u8] = b"dd-sessiond-e2e-v2";
const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct TranscriptRecord {
    pub ts: i64,
    pub kind: String,
    pub data_b64: String,
}

#[derive(Deserialize)]
struct SealedLine {
    v: u32,
    rcpts: Vec<RecipientStanza>,
    bn: String,
    body: String,
}

#[derive(Deserialize)]
struct RecipientStanza {
    epk: String,
    n: String,
    wk: String,
}

/// Derive the per-recipient key-wrapping key — must match the server's
/// `derive_wrap_key`.
fn derive_wrap_key(shared: &[u8; 32], epk: &[u8; 32], rpk: &[u8; 32]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared);
    let mut info = Vec::with_capacity(KDF_INFO_PREFIX.len() + 64);
    info.extend_from_slice(KDF_INFO_PREFIX);
    info.extend_from_slice(epk);
    info.extend_from_slice(rpk);
    let mut out = [0u8; 32];
    hk.expand(&info, &mut out)
        .expect("hkdf expand of 32 bytes never fails");
    out
}

fn hex32(s: &str) -> anyhow::Result<[u8; 32]> {
    let v = hex::decode(s)?;
    let arr: [u8; 32] = v
        .try_into()
        .map_err(|_| anyhow::anyhow!("expected 32 bytes"))?;
    Ok(arr)
}

fn hex12(s: &str) -> anyhow::Result<[u8; 12]> {
    let v = hex::decode(s)?;
    let arr: [u8; 12] = v
        .try_into()
        .map_err(|_| anyhow::anyhow!("expected 12 bytes"))?;
    Ok(arr)
}

/// Open one sealed line with the device secret. Returns `Ok(None)` if this device
/// is not a recipient (no stanza decrypts), `Err` only on malformed input.
pub fn open_record(
    device_secret: &StaticSecret,
    line: &str,
) -> anyhow::Result<Option<TranscriptRecord>> {
    let sealed: SealedLine = serde_json::from_str(line)?;
    if sealed.v != 2 {
        anyhow::bail!("unsupported sealed-record version {}", sealed.v);
    }
    let device_pk = *PublicKey::from(device_secret).as_bytes();
    let bn = hex12(&sealed.bn)?;
    let body = B64.decode(&sealed.body)?;

    for st in &sealed.rcpts {
        let epk = hex32(&st.epk)?;
        let n = hex12(&st.n)?;
        let wk = B64.decode(&st.wk)?;
        let shared = device_secret.diffie_hellman(&PublicKey::from(epk));
        let wrap_key = derive_wrap_key(shared.as_bytes(), &epk, &device_pk);
        // Wrong recipient → AEAD tag mismatch → try the next stanza.
        let Ok(cek) = ChaCha20Poly1305::new(Key::from_slice(&wrap_key))
            .decrypt(Nonce::from_slice(&n), wk.as_ref())
        else {
            continue;
        };
        let cek: [u8; 32] = cek
            .try_into()
            .map_err(|_| anyhow::anyhow!("content key wrong length"))?;
        let plain = ChaCha20Poly1305::new(Key::from_slice(&cek))
            .decrypt(Nonce::from_slice(&bn), body.as_ref())
            .map_err(|e| anyhow::anyhow!("decrypt record body: {e}"))?;
        let record: TranscriptRecord = serde_json::from_slice(&plain)?;
        return Ok(Some(record));
    }
    Ok(None)
}

/// Reconstruct the terminal byte stream from a `replay` response. Handles both
/// the v2 sealed `records` array (decrypted with `device_secret`) and the legacy
/// plaintext `bytes_b64` shape (older agents), so the client works across the
/// server rollout.
pub fn decrypt_replay(device_secret: &StaticSecret, response: &Value) -> anyhow::Result<Vec<u8>> {
    if let Some(records) = response.get("records").and_then(Value::as_array) {
        let mut out = Vec::new();
        for line in records.iter().filter_map(Value::as_str) {
            let Some(record) = open_record(device_secret, line)? else {
                continue; // not our recipient — skip
            };
            if matches!(record.kind.as_str(), "pty" | "stdout" | "stderr") {
                out.extend_from_slice(&B64.decode(&record.data_b64)?);
            }
        }
        return Ok(out);
    }
    if let Some(b64) = response.get("bytes_b64").and_then(Value::as_str) {
        return Ok(B64.decode(b64)?); // legacy plaintext replay
    }
    anyhow::bail!("replay response had neither `records` nor `bytes_b64`")
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;

    /// Seal exactly as `dd/src/sessiond.rs::seal_record` does, so this is a
    /// cross-repo wire-compatibility test, not just a self-consistency one.
    fn seal_record(recipients: &[[u8; 32]], plain: &[u8]) -> String {
        use rand::RngCore;
        let mut rng = OsRng;
        let mut cek = [0u8; 32];
        rng.fill_bytes(&mut cek);
        let mut bn = [0u8; 12];
        rng.fill_bytes(&mut bn);
        let body = ChaCha20Poly1305::new(Key::from_slice(&cek))
            .encrypt(Nonce::from_slice(&bn), plain)
            .unwrap();

        let mut rcpts = Vec::new();
        for r in recipients {
            let mut e_bytes = [0u8; 32];
            rng.fill_bytes(&mut e_bytes);
            let e_sk = StaticSecret::from(e_bytes);
            let e_pk = PublicKey::from(&e_sk);
            let shared = e_sk.diffie_hellman(&PublicKey::from(*r));
            let wrap_key = derive_wrap_key(shared.as_bytes(), e_pk.as_bytes(), r);
            let mut n = [0u8; 12];
            rng.fill_bytes(&mut n);
            let wk = ChaCha20Poly1305::new(Key::from_slice(&wrap_key))
                .encrypt(Nonce::from_slice(&n), cek.as_ref())
                .unwrap();
            rcpts.push(serde_json::json!({
                "epk": hex::encode(e_pk.as_bytes()),
                "n": hex::encode(n),
                "wk": B64.encode(wk),
            }));
        }
        serde_json::json!({
            "v": 2, "rcpts": rcpts, "bn": hex::encode(bn), "body": B64.encode(body),
        })
        .to_string()
    }

    fn record_line(recipients: &[[u8; 32]], kind: &str, data: &[u8]) -> String {
        let rec = serde_json::json!({ "ts": 1, "kind": kind, "data_b64": B64.encode(data) });
        seal_record(recipients, serde_json::to_string(&rec).unwrap().as_bytes())
    }

    fn device() -> (StaticSecret, [u8; 32]) {
        let sk = StaticSecret::random_from_rng(OsRng);
        let pk = *PublicKey::from(&sk).as_bytes();
        (sk, pk)
    }

    #[test]
    fn opens_record_for_recipient() {
        let (sk, pk) = device();
        let line = record_line(&[pk], "pty", b"hello");
        let rec = open_record(&sk, &line).unwrap().expect("recipient");
        assert_eq!(rec.kind, "pty");
        assert_eq!(B64.decode(rec.data_b64).unwrap(), b"hello");
    }

    #[test]
    fn non_recipient_gets_none() {
        let (_sk_a, pk_a) = device();
        let (sk_b, _pk_b) = device(); // B is not a recipient
        let line = record_line(&[pk_a], "pty", b"secret");
        assert!(open_record(&sk_b, &line).unwrap().is_none());
    }

    #[test]
    fn multi_recipient_each_opens() {
        let (sk_a, pk_a) = device();
        let (sk_b, pk_b) = device();
        let line = record_line(&[pk_a, pk_b], "pty", b"shared");
        assert!(open_record(&sk_a, &line).unwrap().is_some());
        assert!(open_record(&sk_b, &line).unwrap().is_some());
    }

    #[test]
    fn decrypt_replay_reconstructs_pty_stream_and_skips_meta() {
        let (sk, pk) = device();
        let records = vec![
            Value::String(record_line(&[pk], "meta", b"{...}")),
            Value::String(record_line(&[pk], "pty", b"foo")),
            Value::String(record_line(&[pk], "stdout", b"bar")),
        ];
        let resp = serde_json::json!({ "id": "s", "version": 2, "records": records });
        assert_eq!(decrypt_replay(&sk, &resp).unwrap(), b"foobar");
    }

    #[test]
    fn decrypt_replay_handles_legacy_plaintext() {
        let (sk, _pk) = device();
        let resp = serde_json::json!({ "id": "s", "bytes_b64": B64.encode(b"legacy") });
        assert_eq!(decrypt_replay(&sk, &resp).unwrap(), b"legacy");
    }
}
