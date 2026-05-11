mod ita;

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{anyhow, Context};
use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use rand::rngs::OsRng;
use reqwest::Client as HttpClient;
use serde_json::Value;
use snow::{Builder, TransportState};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use x25519_dalek::{PublicKey, StaticSecret};

const NOISE_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";
const MAX_NOISE_MSG: usize = 65535;
const ATTACH_CHUNK: usize = 4096;
const ATTACH_KEEPALIVE_INTERVAL: Duration = Duration::from_secs(25);
const CTRL_D: u8 = 0x04;
const CTRL_RIGHT_BRACKET: u8 = 0x1d;

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;
type WsSink = futures_util::stream::SplitSink<WsStream, WsMessage>;
type WsRead = futures_util::stream::SplitStream<WsStream>;

#[derive(Debug, Clone)]
pub struct IntelTrustAuthority {
    pub api_key: String,
    pub base_url: String,
    pub jwks_url: String,
    pub issuer: String,
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

pub struct NoiseConnection {
    transport: TransportState,
    sink: WsSink,
    stream: WsRead,
}

impl NoiseConnection {
    async fn call(&mut self, request: Value) -> anyhow::Result<Value> {
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

pub async fn replay_session(
    conn: &mut NoiseConnection,
    id: &str,
    max_bytes: Option<usize>,
) -> anyhow::Result<Value> {
    let mut request = serde_json::json!({
        "method": "shell.replay_session",
        "id": id,
    });
    if let Some(max_bytes) = max_bytes {
        request["max_bytes"] = serde_json::json!(max_bytes);
    }
    conn.call(request).await
}

async fn resize_session(
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

pub async fn attach_session(
    mut conn: NoiseConnection,
    id: &str,
    resize_opts: Option<ConnectionOptions>,
) -> anyhow::Result<()> {
    let initial_size = current_terminal_size();
    if let Some(size) = initial_size {
        if let Err(error) = resize_session(&mut conn, id, size.cols, size.rows).await {
            eprintln!("warning: initial terminal resize failed: {error}");
        }
    }

    let ack = conn
        .call(serde_json::json!({
            "method": "shell.attach_session",
            "id": id,
            "tail": true,
        }))
        .await?;
    if ack.get("error").is_some() {
        anyhow::bail!("attach failed: {}", serde_json::to_string(&ack)?);
    }

    eprintln!("attached; Ctrl-] detaches, Ctrl-D sends EOF and disconnects");

    let _raw = RawMode::enter()?;
    let resize_task = resize_opts.map(|opts| {
        tokio::spawn(resize_on_terminal_change(
            opts,
            id.to_string(),
            initial_size,
        ))
    });
    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut in_buf = [0u8; ATTACH_CHUNK];
    let mut keepalive = attach_keepalive();

    loop {
        tokio::select! {
            _ = keepalive.tick() => {
                conn.sink.send(WsMessage::Ping(Vec::new().into())).await?;
            }
            n = stdin.read(&mut in_buf) => {
                let n = n?;
                if n == 0 {
                    break;
                }
                match attach_input_action(&in_buf[..n]) {
                    AttachInputAction::Forward => {
                        send_encrypted(&mut conn.transport, &mut conn.sink, &in_buf[..n]).await?;
                    }
                    AttachInputAction::ForwardThenDisconnect => {
                        send_encrypted(&mut conn.transport, &mut conn.sink, &in_buf[..n]).await?;
                        break;
                    }
                    AttachInputAction::Disconnect => break,
                }
            }
            frame = next_binary(&mut conn.stream) => {
                let Some(cipher) = frame? else {
                    break;
                };
                let mut plain = vec![0u8; cipher.len()];
                let n = conn.transport.read_message(&cipher, &mut plain)?;
                stdout.write_all(&plain[..n]).await?;
                stdout.flush().await?;
            }
        }
    }
    if let Some(task) = resize_task {
        task.abort();
    }
    Ok(())
}

pub async fn attach_session_stream<F>(
    mut conn: NoiseConnection,
    id: &str,
    mut shutdown: watch::Receiver<bool>,
    mut input: Option<mpsc::UnboundedReceiver<Vec<u8>>>,
    mut on_open: impl FnMut() -> anyhow::Result<()> + Send,
    mut on_bytes: F,
) -> anyhow::Result<()>
where
    F: FnMut(&[u8]) -> anyhow::Result<()> + Send,
{
    let ack = conn
        .call(serde_json::json!({
            "method": "shell.attach_session",
            "id": id,
            "tail": true,
        }))
        .await?;
    if ack.get("error").is_some() {
        anyhow::bail!("attach failed: {}", serde_json::to_string(&ack)?);
    }
    on_open()?;
    let mut keepalive = attach_keepalive();

    loop {
        tokio::select! {
            _ = keepalive.tick() => {
                conn.sink.send(WsMessage::Ping(Vec::new().into())).await?;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            maybe_bytes = async {
                match input.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                let Some(bytes) = maybe_bytes else {
                    input = None;
                    continue;
                };
                if bytes.is_empty() {
                    continue;
                }
                send_encrypted(&mut conn.transport, &mut conn.sink, &bytes).await?;
            }
            frame = next_binary(&mut conn.stream) => {
                let Some(cipher) = frame? else {
                    break;
                };
                let mut plain = vec![0u8; cipher.len()];
                let n = conn.transport.read_message(&cipher, &mut plain)?;
                on_bytes(&plain[..n])?;
            }
        }
    }

    Ok(())
}

fn attach_keepalive() -> tokio::time::Interval {
    let mut interval = tokio::time::interval_at(
        tokio::time::Instant::now() + ATTACH_KEEPALIVE_INTERVAL,
        ATTACH_KEEPALIVE_INTERVAL,
    );
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    interval
}

#[derive(Debug, Eq, PartialEq)]
enum AttachInputAction {
    Forward,
    ForwardThenDisconnect,
    Disconnect,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
struct TerminalSize {
    cols: u64,
    rows: u64,
}

#[cfg(unix)]
async fn resize_on_terminal_change(
    opts: ConnectionOptions,
    id: String,
    mut last_size: Option<TerminalSize>,
) {
    let mut signals =
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change()) {
            Ok(signals) => signals,
            Err(error) => {
                eprintln!("warning: could not watch terminal resize events: {error}");
                return;
            }
        };

    while signals.recv().await.is_some() {
        let Some(size) = current_terminal_size() else {
            continue;
        };
        if Some(size) == last_size {
            continue;
        }
        match connect(&opts).await {
            Ok(mut conn) => match resize_session(&mut conn, &id, size.cols, size.rows).await {
                Ok(_) => last_size = Some(size),
                Err(error) => eprintln!("warning: terminal resize failed: {error}"),
            },
            Err(error) => eprintln!("warning: terminal resize connect failed: {error}"),
        }
    }
}

#[cfg(not(unix))]
async fn resize_on_terminal_change(
    _opts: ConnectionOptions,
    _id: String,
    _last_size: Option<TerminalSize>,
) {
}

fn current_terminal_size() -> Option<TerminalSize> {
    #[cfg(unix)]
    {
        terminal_size_for_fd(libc::STDOUT_FILENO)
            .or_else(|| terminal_size_for_fd(libc::STDIN_FILENO))
            .or_else(|| terminal_size_for_fd(libc::STDERR_FILENO))
    }
    #[cfg(not(unix))]
    {
        None
    }
}

#[cfg(unix)]
fn terminal_size_for_fd(fd: libc::c_int) -> Option<TerminalSize> {
    if unsafe { libc::isatty(fd) } != 1 {
        return None;
    }

    let mut winsize = std::mem::MaybeUninit::<libc::winsize>::uninit();
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, winsize.as_mut_ptr()) } != 0 {
        return None;
    }
    let winsize = unsafe { winsize.assume_init() };
    if winsize.ws_col == 0 || winsize.ws_row == 0 {
        return None;
    }
    Some(TerminalSize {
        cols: winsize.ws_col.into(),
        rows: winsize.ws_row.into(),
    })
}

fn attach_input_action(bytes: &[u8]) -> AttachInputAction {
    match bytes {
        [CTRL_D] => AttachInputAction::ForwardThenDisconnect,
        [CTRL_RIGHT_BRACKET] => AttachInputAction::Disconnect,
        _ => AttachInputAction::Forward,
    }
}

pub fn session_id(value: &Value) -> anyhow::Result<String> {
    if let Some(error) = value.get("error") {
        anyhow::bail!("create failed: {error}");
    }
    value
        .get("id")
        .or_else(|| value.pointer("/session/id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("create response did not include a session id: {value}"))
}

async fn load_or_create_key(path: &Path) -> anyhow::Result<StaticSecret> {
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

fn public_hex(secret: &StaticSecret) -> String {
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

fn health_url(base_url: &str) -> String {
    format!("{}/health", normalize_http_base(base_url))
}

fn noise_ws_url(base_url: &str) -> String {
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
    let quote_b64 = body
        .pointer("/noise/quote_b64")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("{url} did not include noise.quote_b64"))?;
    let bytes = hex::decode(pubkey_hex).context("decode noise.pubkey_hex")?;
    if bytes.len() != 32 {
        anyhow::bail!(
            "noise.pubkey_hex decoded to {} bytes, expected 32",
            bytes.len()
        );
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    verify_quote_binding(http, quote_b64, &out, &opts.quote_verification).await?;
    Ok(out)
}

async fn verify_quote_binding(
    http: &HttpClient,
    quote_b64: &str,
    pubkey: &[u8; 32],
    verification: &QuoteVerification,
) -> anyhow::Result<()> {
    let QuoteVerification::IntelTrustAuthority(config) = verification else {
        eprintln!("warning: skipping agent TDX quote verification by explicit request");
        return Ok(());
    };

    let token = ita::mint(http, &config.base_url, &config.api_key, quote_b64)
        .await
        .map_err(|e| anyhow!("ITA quote appraisal failed: {e}"))?;
    let verifier = ita::Verifier::new(http.clone(), config.jwks_url.clone(), config.issuer.clone());
    let claims = verifier
        .verify(&token)
        .await
        .map_err(|e| anyhow!("ITA token verification failed: {e}"))?;
    let report_data = claims
        .report_data
        .as_deref()
        .ok_or_else(|| anyhow!("ITA token missing attester_held_data/report_data"))?;
    verify_report_data(report_data, pubkey)
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

struct RawMode {
    #[cfg(unix)]
    original: Option<libc::termios>,
}

impl RawMode {
    fn enter() -> anyhow::Result<Self> {
        #[cfg(unix)]
        {
            if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1 {
                return Ok(Self { original: None });
            }
            let mut original = std::mem::MaybeUninit::<libc::termios>::uninit();
            if unsafe { libc::tcgetattr(libc::STDIN_FILENO, original.as_mut_ptr()) } != 0 {
                return Err(std::io::Error::last_os_error()).context("tcgetattr");
            }
            let original = unsafe { original.assume_init() };
            let mut raw = original;
            unsafe { libc::cfmakeraw(&mut raw) };
            if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
                return Err(std::io::Error::last_os_error()).context("tcsetattr raw");
            }
            Ok(Self {
                original: Some(original),
            })
        }
        #[cfg(not(unix))]
        {
            Ok(Self {})
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(original) = &self.original {
            let _ = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
        }
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

    #[test]
    fn attach_input_detaches_on_ctrl_right_bracket() {
        assert_eq!(
            attach_input_action(&[CTRL_RIGHT_BRACKET]),
            AttachInputAction::Disconnect
        );
    }

    #[test]
    fn attach_input_sends_eof_then_disconnects_on_ctrl_d() {
        assert_eq!(
            attach_input_action(&[CTRL_D]),
            AttachInputAction::ForwardThenDisconnect
        );
    }

    #[test]
    fn attach_input_forwards_regular_bytes() {
        assert_eq!(attach_input_action(b"exit\n"), AttachInputAction::Forward);
    }
}
