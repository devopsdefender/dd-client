mod ita;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context};
use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use rand::rngs::OsRng;
use reqwest::Client as HttpClient;
use serde_json::Value;
use snow::{Builder, TransportState};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use x25519_dalek::{PublicKey, StaticSecret};

const NOISE_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";
const MAX_NOISE_MSG: usize = 65535;

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type WsSink = futures_util::stream::SplitSink<WsStream, WsMessage>;
type WsRead = futures_util::stream::SplitStream<WsStream>;

#[derive(Debug, Clone)]
pub struct IntelTrustAuthority {
    /// Intel's public JWKS endpoint. Verification only — no API key, no account:
    /// the agent mints the token; the client just checks the signature.
    pub jwks_url: String,
    pub issuer: String,
    /// Expected MRTDs (lowercase hex), any-of. Empty = measurement unpinned
    /// (verifies genuineness but not *which code* — warns). Pin to a value from a
    /// source independent of the agent (committed pin / signed release manifest).
    pub expected_mrtds: Vec<String>,
    /// Required TCB status when pinned (e.g. "UpToDate").
    pub expected_tcb: Option<String>,
}

#[derive(Debug, Clone)]
pub enum QuoteVerification {
    IntelTrustAuthority(IntelTrustAuthority),
    InsecureSkip,
}

#[derive(Debug, Clone)]
pub struct ConnectionOptions {
    pub agent_url: String,
    pub key_path: PathBuf,
    pub quote_verification: QuoteVerification,
}

#[derive(Debug, Default, Clone)]
pub struct CreateSessionRequest {
    pub recipe: Option<String>,
    pub name: Option<String>,
    pub command: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ExecRequest {
    pub cmd: Vec<String>,
    pub timeout_secs: u64,
}

pub struct NoiseConnection {
    transport: TransportState,
    sink: WsSink,
    stream: WsRead,
}

impl NoiseConnection {
    pub async fn call(&mut self, request: Value) -> anyhow::Result<Value> {
        let plain = serde_json::to_vec(&request)?;
        send_encrypted(&mut self.transport, &mut self.sink, &plain).await?;
        let cipher = next_binary(&mut self.stream)
            .await?
            .ok_or_else(|| anyhow!("Noise websocket closed before response"))?;
        let mut out = vec![0u8; cipher.len()];
        let n = self.transport.read_message(&cipher, &mut out)?;
        out.truncate(n);
        Ok(serde_json::from_slice(&out)?)
    }

    /// Split into independently-ownable write/read halves so a caller can run a
    /// duplex pump loop (e.g. the session engine forwarding keystrokes while
    /// streaming PTY output). The Noise transport (encryption) stays inside core,
    /// shared between the halves behind a brief, non-async lock — the lock is
    /// never held across an `.await`.
    pub fn split(self) -> (NoiseWriter, NoiseReader) {
        let transport = Arc::new(Mutex::new(self.transport));
        (
            NoiseWriter {
                transport: transport.clone(),
                sink: self.sink,
            },
            NoiseReader {
                transport,
                stream: self.stream,
            },
        )
    }
}

/// Write half of a split [`NoiseConnection`]. Encrypts plaintext into Noise
/// transport frames and sends them.
pub struct NoiseWriter {
    transport: Arc<Mutex<TransportState>>,
    sink: WsSink,
}

impl NoiseWriter {
    /// Encrypt `plain` and send it as one Noise transport frame.
    pub async fn send(&mut self, plain: &[u8]) -> anyhow::Result<()> {
        let frame = {
            let mut transport = self
                .transport
                .lock()
                .map_err(|_| anyhow!("noise transport lock poisoned"))?;
            let mut cipher = vec![0u8; plain.len() + 16];
            let n = transport.write_message(plain, &mut cipher)?;
            cipher.truncate(n);
            cipher
        };
        self.sink.send(WsMessage::Binary(frame.into())).await?;
        Ok(())
    }
}

/// Read half of a split [`NoiseConnection`]. Receives Noise transport frames and
/// decrypts them.
pub struct NoiseReader {
    transport: Arc<Mutex<TransportState>>,
    stream: WsRead,
}

impl NoiseReader {
    /// Receive and decrypt the next Noise transport frame. `Ok(None)` once the
    /// socket closes.
    pub async fn recv(&mut self) -> anyhow::Result<Option<Vec<u8>>> {
        let Some(cipher) = next_binary(&mut self.stream).await? else {
            return Ok(None);
        };
        let mut plain = vec![0u8; cipher.len()];
        let n = {
            let mut transport = self
                .transport
                .lock()
                .map_err(|_| anyhow!("noise transport lock poisoned"))?;
            transport.read_message(&cipher, &mut plain)?
        };
        plain.truncate(n);
        Ok(Some(plain))
    }
}

pub async fn connect(opts: &ConnectionOptions) -> anyhow::Result<NoiseConnection> {
    let http = HttpClient::builder().build()?;
    let secret = load_or_create_key(&opts.key_path).await?;
    let server_pubkey = fetch_and_verify_server_pubkey(&http, opts).await?;
    let ws_url = noise_ws_url(&opts.agent_url);

    let (ws, _response) = connect_async(&ws_url)
        .await
        .with_context(|| format!("connect {ws_url}"))?;
    let (mut sink, mut stream) = ws.split();

    let mut handshake = Builder::new(NOISE_PATTERN.parse()?)
        .local_private_key(secret.as_bytes())
        .remote_public_key(&server_pubkey)
        .build_initiator()?;

    let mut first = [0u8; MAX_NOISE_MSG];
    let n = handshake.write_message(&[], &mut first)?;
    sink.send(WsMessage::Binary(first[..n].to_vec().into()))
        .await?;

    let second = next_binary(&mut stream)
        .await?
        .ok_or_else(|| anyhow!("Noise websocket closed during handshake"))?;
    let mut payload = [0u8; MAX_NOISE_MSG];
    handshake.read_message(&second, &mut payload)?;

    Ok(NoiseConnection {
        transport: handshake.into_transport_mode()?,
        sink,
        stream,
    })
}

pub async fn list_recipes(conn: &mut NoiseConnection) -> anyhow::Result<Value> {
    conn.call(serde_json::json!({"method": "shell.list_recipes"}))
        .await
}

pub async fn list_sessions(conn: &mut NoiseConnection) -> anyhow::Result<Value> {
    conn.call(serde_json::json!({"method": "shell.list_sessions"}))
        .await
}

pub async fn create_session(
    conn: &mut NoiseConnection,
    request: &CreateSessionRequest,
) -> anyhow::Result<Value> {
    let mut body = serde_json::Map::from_iter([(
        "method".to_string(),
        Value::String("shell.create_session".into()),
    )]);
    if let Some(recipe) = request.recipe.as_deref() {
        body.insert("recipe_id".into(), Value::String(recipe.into()));
    }
    if let Some(name) = request.name.as_deref() {
        body.insert("name".into(), Value::String(name.into()));
    }
    if let Some(command) = request.command.as_deref() {
        body.insert("command".into(), Value::String(command.into()));
    }
    conn.call(Value::Object(body)).await
}

pub async fn replay_session(conn: &mut NoiseConnection, id: &str) -> anyhow::Result<Value> {
    conn.call(serde_json::json!({
        "method": "shell.replay_session",
        "id": id,
    }))
    .await
}

pub async fn resize_session(
    conn: &mut NoiseConnection,
    id: &str,
    cols: u64,
    rows: u64,
) -> anyhow::Result<Value> {
    conn.call(serde_json::json!({
        "method": "shell.resize_session",
        "id": id,
        "cols": cols,
        "rows": rows,
    }))
    .await
}

pub async fn close_session(conn: &mut NoiseConnection, id: &str) -> anyhow::Result<Value> {
    conn.call(serde_json::json!({
        "method": "shell.close_session",
        "id": id,
    }))
    .await
}

pub async fn exec(conn: &mut NoiseConnection, request: &ExecRequest) -> anyhow::Result<Value> {
    conn.call(serde_json::json!({
        "method": "exec",
        "cmd": request.cmd,
        "timeout_secs": request.timeout_secs,
    }))
    .await
}

pub fn session_id(value: &Value) -> anyhow::Result<String> {
    if let Some(error) = value.get("error") {
        // The Noise gateway wraps upstream failures as {error, detail}; the detail
        // carries the real cause (e.g. "unknown recipe: codex"). Surface both.
        let msg = error
            .as_str()
            .map(String::from)
            .unwrap_or_else(|| error.to_string());
        match value.get("detail").and_then(Value::as_str) {
            Some(detail) => anyhow::bail!("create failed: {msg}: {detail}"),
            None => anyhow::bail!("create failed: {msg}"),
        }
    }
    value
        .get("id")
        .or_else(|| value.pointer("/session/id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("create response did not include a session id: {value}"))
}

pub async fn load_or_create_key(path: &Path) -> anyhow::Result<StaticSecret> {
    match tokio::fs::read(path).await {
        Ok(bytes) if bytes.len() == 32 => {
            let mut key = [0u8; 32];
            key.copy_from_slice(&bytes);
            Ok(StaticSecret::from(key))
        }
        Ok(bytes) => anyhow::bail!("{} is {} bytes, expected 32", path.display(), bytes.len()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let secret = StaticSecret::random_from_rng(OsRng);
            persist_key(path, secret.as_bytes()).await?;
            Ok(secret)
        }
        Err(e) => Err(e).with_context(|| format!("read {}", path.display())),
    }
}

pub async fn public_key_hex(path: &Path) -> anyhow::Result<String> {
    let secret = load_or_create_key(path).await?;
    Ok(public_hex(&secret))
}

pub fn public_hex(secret: &StaticSecret) -> String {
    hex::encode(PublicKey::from(secret).as_bytes())
}

pub fn enrollment_url(cp_url: &str, pubkey_hex: &str, label: &str) -> String {
    format!(
        "{}/admin/enroll?pubkey={}&label={}",
        normalize_http_base(cp_url),
        pubkey_hex,
        urlencoding::encode(label)
    )
}

pub fn health_url(base_url: &str) -> String {
    format!("{}/health", normalize_http_base(base_url))
}

pub fn noise_ws_url(base_url: &str) -> String {
    let base = normalize_http_base(base_url);
    let ws_base = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        base
    };
    format!("{}/noise/ws", ws_base.trim_end_matches('/'))
}

async fn persist_key(path: &Path, bytes: &[u8; 32]) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let tmp = path.with_extension("key.tmp");
    tokio::fs::write(&tmp, bytes).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).await?;
    }
    tokio::fs::rename(&tmp, path).await?;
    Ok(())
}

async fn fetch_and_verify_server_pubkey(
    http: &HttpClient,
    opts: &ConnectionOptions,
) -> anyhow::Result<[u8; 32]> {
    let url = health_url(&opts.agent_url);
    let body: Value = http
        .get(&url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .json()
        .await
        .with_context(|| format!("parse {url}"))?;
    let pubkey_hex = body
        .pointer("/noise/pubkey_hex")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("{url} did not include noise.pubkey_hex"))?;
    // The agent mints an ITA appraisal of its Noise quote and serves it here; the
    // client only verifies it (public JWKS — no account). Optional so the
    // InsecureSkip path and older agents still work.
    let ita_token = body.pointer("/noise/ita_token").and_then(Value::as_str);
    let bytes = hex::decode(pubkey_hex).context("decode noise.pubkey_hex")?;
    if bytes.len() != 32 {
        anyhow::bail!(
            "noise.pubkey_hex decoded to {} bytes, expected 32",
            bytes.len()
        );
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    verify_quote_binding(http, ita_token, &out, &opts.quote_verification).await?;
    Ok(out)
}

async fn verify_quote_binding(
    http: &HttpClient,
    ita_token: Option<&str>,
    pubkey: &[u8; 32],
    verification: &QuoteVerification,
) -> anyhow::Result<()> {
    let QuoteVerification::IntelTrustAuthority(config) = verification else {
        eprintln!("warning: skipping agent TDX quote verification by explicit request");
        return Ok(());
    };

    let token = ita_token.ok_or_else(|| {
        anyhow!(
            "agent /health did not include noise.ita_token; update the agent or \
             pass --insecure-skip-quote-verify"
        )
    })?;
    let verifier = ita::Verifier::new(http.clone(), config.jwks_url.clone(), config.issuer.clone());
    let claims = verifier
        .verify(token)
        .await
        .map_err(|e| anyhow!("ITA token verification failed: {e}"))?;
    let report_data = claims
        .report_data
        .as_deref()
        .ok_or_else(|| anyhow!("ITA token missing attester_held_data/report_data"))?;
    verify_report_data(report_data, pubkey)?;
    verify_measurement(&claims, config)
}

/// Pin the enclave measurement: attestation proves a genuine TDX VM, but only
/// matching the MRTD proves it's running *our* code. Unpinned ⇒ warn (don't fail).
fn verify_measurement(claims: &ita::Claims, config: &IntelTrustAuthority) -> anyhow::Result<()> {
    if config.expected_mrtds.is_empty() {
        eprintln!(
            "warning: agent measurement is unpinned (no --expected-mrtd); attestation proves a \
             genuine TDX enclave but not which code it runs"
        );
        return Ok(());
    }
    let mrtd = claims.mrtd.as_deref().unwrap_or("").to_lowercase();
    if !config.expected_mrtds.contains(&mrtd) {
        anyhow::bail!(
            "agent MRTD {} not in expected allowlist",
            if mrtd.is_empty() { "<none>" } else { &mrtd }
        );
    }
    if let Some(want) = &config.expected_tcb {
        let got = claims.tcb_status.as_deref().unwrap_or("");
        if got != want {
            anyhow::bail!("agent TCB status {got:?} != expected {want:?}");
        }
    }
    Ok(())
}

fn verify_report_data(report_data: &str, pubkey: &[u8; 32]) -> anyhow::Result<()> {
    let bytes = decode_report_data(report_data)?;
    match bytes.len() {
        32 if bytes.as_slice() == pubkey => Ok(()),
        64 if bytes[..32] == pubkey[..] && bytes[32..].iter().all(|b| *b == 0) => Ok(()),
        32 | 64 => anyhow::bail!("TDX report_data does not bind expected Noise public key"),
        n => anyhow::bail!("TDX report_data decoded to {n} bytes, expected 32 or 64"),
    }
}

fn decode_report_data(report_data: &str) -> anyhow::Result<Vec<u8>> {
    let s = report_data.trim();
    let hexish = s.strip_prefix("0x").unwrap_or(s);
    if hexish.len().is_multiple_of(2) && hexish.bytes().all(|b| b.is_ascii_hexdigit()) {
        return hex::decode(hexish).context("decode ITA report_data hex");
    }
    for engine in [
        &base64::engine::general_purpose::STANDARD,
        &base64::engine::general_purpose::STANDARD_NO_PAD,
        &base64::engine::general_purpose::URL_SAFE,
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
    ] {
        if let Ok(bytes) = engine.decode(s) {
            return Ok(bytes);
        }
    }
    anyhow::bail!("ITA report_data is neither hex nor base64")
}

async fn send_encrypted(
    transport: &mut TransportState,
    sink: &mut WsSink,
    plain: &[u8],
) -> anyhow::Result<()> {
    let mut cipher = vec![0u8; plain.len() + 16];
    let n = transport.write_message(plain, &mut cipher)?;
    cipher.truncate(n);
    sink.send(WsMessage::Binary(cipher.into())).await?;
    Ok(())
}

async fn next_binary(stream: &mut WsRead) -> anyhow::Result<Option<Vec<u8>>> {
    while let Some(msg) = stream.next().await {
        match msg? {
            WsMessage::Binary(b) => return Ok(Some(b.to_vec())),
            WsMessage::Close(_) => return Ok(None),
            WsMessage::Text(_) | WsMessage::Ping(_) | WsMessage::Pong(_) | WsMessage::Frame(_) => {
                continue
            }
        }
    }
    Ok(None)
}

fn normalize_http_base(base_url: &str) -> String {
    let trimmed = base_url.trim().trim_end_matches('/');
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_urls_from_bare_host() {
        assert_eq!(
            health_url("agent.example.com/"),
            "https://agent.example.com/health"
        );
        assert_eq!(
            noise_ws_url("agent.example.com/"),
            "wss://agent.example.com/noise/ws"
        );
    }

    #[test]
    fn keeps_local_http_scheme() {
        assert_eq!(
            health_url("http://127.0.0.1:8080"),
            "http://127.0.0.1:8080/health"
        );
        assert_eq!(
            noise_ws_url("http://127.0.0.1:8080"),
            "ws://127.0.0.1:8080/noise/ws"
        );
    }

    #[test]
    fn enrollment_url_encodes_label() {
        assert_eq!(
            enrollment_url("https://cp.example.com/", "abcd", "me laptop"),
            "https://cp.example.com/admin/enroll?pubkey=abcd&label=me%20laptop"
        );
    }

    #[test]
    fn report_data_accepts_64_byte_hex_binding() {
        let mut report = [0u8; 64];
        report[..32].fill(7);
        let pubkey = [7u8; 32];
        verify_report_data(&hex::encode(report), &pubkey).unwrap();
    }

    #[test]
    fn report_data_rejects_wrong_key() {
        let mut report = [0u8; 64];
        report[..32].fill(7);
        let pubkey = [8u8; 32];
        assert!(verify_report_data(&hex::encode(report), &pubkey).is_err());
    }

    #[test]
    fn report_data_accepts_base64_binding() {
        let mut report = [0u8; 64];
        report[..32].fill(9);
        let pubkey = [9u8; 32];
        let encoded = base64::engine::general_purpose::STANDARD.encode(report);
        verify_report_data(&encoded, &pubkey).unwrap();
    }

    fn ita_config(mrtds: &[&str], tcb: Option<&str>) -> IntelTrustAuthority {
        IntelTrustAuthority {
            jwks_url: String::new(),
            issuer: String::new(),
            expected_mrtds: mrtds.iter().map(|s| s.to_string()).collect(),
            expected_tcb: tcb.map(String::from),
        }
    }

    fn claims(mrtd: &str, tcb: &str) -> ita::Claims {
        ita::Claims {
            mrtd: Some(mrtd.into()),
            tcb_status: Some(tcb.into()),
            ..Default::default()
        }
    }

    #[test]
    fn measurement_unpinned_warns_but_passes() {
        assert!(verify_measurement(&claims("aa", "OutOfDate"), &ita_config(&[], None)).is_ok());
    }

    #[test]
    fn measurement_pinned_accepts_match_rejects_others() {
        let cfg = ita_config(&["aa", "bb"], Some("UpToDate"));
        assert!(verify_measurement(&claims("bb", "UpToDate"), &cfg).is_ok());
        assert!(verify_measurement(&claims("cc", "UpToDate"), &cfg).is_err()); // wrong mrtd
        assert!(verify_measurement(&claims("aa", "OutOfDate"), &cfg).is_err()); // bad tcb
    }
}
