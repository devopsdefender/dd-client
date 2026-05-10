use std::ffi::{CStr, CString};
use std::future::Future;
use std::os::raw::{c_char, c_void};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;

use base64::Engine as _;
use dd_client_core::{
    attach_session_stream, connect, replay_session, ConnectionOptions, IntelTrustAuthority,
    QuoteVerification,
};
use std::collections::HashMap;
use tokio::sync::watch;

const DEFAULT_ITA_BASE_URL: &str = "https://api.trustauthority.intel.com";
const DEFAULT_ITA_JWKS_URL: &str = "https://portal.trustauthority.intel.com/certs";
const DEFAULT_ITA_ISSUER: &str = "https://portal.trustauthority.intel.com";
const DEFAULT_REPLAY_MAX_BYTES: usize = 32 * 1024;
const MAX_REPLAY_BYTES: usize = 32 * 1024;

type StreamCallback = extern "C" fn(u64, *const c_char, *mut c_void);

struct StreamControl {
    shutdown: watch::Sender<bool>,
}

static NEXT_STREAM_ID: AtomicU64 = AtomicU64::new(1);
static STREAMS: OnceLock<Mutex<HashMap<u64, StreamControl>>> = OnceLock::new();

#[no_mangle]
pub extern "C" fn dd_client_import_key(
    key_path: *const c_char,
    key_content: *const c_char,
) -> *mut c_char {
    into_c_string(import_key_response(key_path, key_content))
}

#[no_mangle]
pub extern "C" fn dd_client_replay_session(request_json: *const c_char) -> *mut c_char {
    into_c_string(replay_session_response(request_json))
}

#[no_mangle]
pub extern "C" fn dd_client_attach_stream_start(
    request_json: *const c_char,
    callback: Option<StreamCallback>,
    context: *mut c_void,
) -> u64 {
    attach_stream_start(request_json, callback, context).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn dd_client_attach_stream_stop(handle: u64) {
    if handle == 0 {
        return;
    }
    if let Some(control) = streams()
        .lock()
        .ok()
        .and_then(|mut map| map.remove(&handle))
    {
        let _ = control.shutdown.send(true);
    }
}

#[no_mangle]
/// # Safety
///
/// `value` must be a pointer returned by this library, and it must not have
/// already been freed.
pub unsafe extern "C" fn dd_client_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    let _ = unsafe { CString::from_raw(value) };
}

fn attach_stream_start(
    request_json: *const c_char,
    callback: Option<StreamCallback>,
    context: *mut c_void,
) -> Result<u64, String> {
    let callback = callback.ok_or_else(|| "callback is required".to_string())?;
    let request_json = required_c_string(request_json, "request_json")?;
    let request: serde_json::Value =
        serde_json::from_str(&request_json).map_err(|e| format!("parse request_json: {e}"))?;
    let opts = connection_options_from_request(&request)?;
    let id = required_json_string(&request, "id")?;
    let (shutdown, shutdown_rx) = watch::channel(false);
    let handle = NEXT_STREAM_ID.fetch_add(1, Ordering::Relaxed);

    streams()
        .lock()
        .map_err(|_| "stream registry lock poisoned".to_string())?
        .insert(handle, StreamControl { shutdown });

    let context_addr = context as usize;
    let worker = thread::Builder::new()
        .name(format!("dd-client-attach-{handle}"))
        .stack_size(16 * 1024 * 1024)
        .spawn(move || {
            let result = runtime().and_then(|runtime| {
                runtime
                    .block_on(async move {
                        let conn = connect(&opts).await?;
                        attach_session_stream(
                            conn,
                            &id,
                            shutdown_rx,
                            || {
                                emit_stream_event(
                                    callback,
                                    context_addr,
                                    handle,
                                    serde_json::json!({"type": "open", "id": id}),
                                );
                                Ok(())
                            },
                            |bytes| {
                                emit_stream_event(
                                    callback,
                                    context_addr,
                                    handle,
                                    serde_json::json!({
                                        "type": "bytes",
                                        "data_b64": base64::engine::general_purpose::STANDARD.encode(bytes),
                                    }),
                                );
                                Ok(())
                            },
                        )
                        .await
                    })
                    .map_err(|e| e.to_string())
            });
            if let Err(error) = result {
                emit_stream_event(
                    callback,
                    context_addr,
                    handle,
                    serde_json::json!({"type": "error", "message": error}),
                );
            }
            if let Ok(mut map) = streams().lock() {
                map.remove(&handle);
            }
            emit_stream_event(
                callback,
                context_addr,
                handle,
                serde_json::json!({"type": "close"}),
            );
        });

    if let Err(error) = worker {
        if let Ok(mut map) = streams().lock() {
            map.remove(&handle);
        }
        return Err(format!("spawn attach stream: {error}"));
    }

    Ok(handle)
}

fn emit_stream_event(
    callback: StreamCallback,
    context_addr: usize,
    handle: u64,
    event: serde_json::Value,
) {
    if let Ok(event_json) = serde_json::to_string(&event) {
        if let Ok(c_event) = CString::new(event_json) {
            callback(handle, c_event.as_ptr(), context_addr as *mut c_void);
        }
    }
}

fn streams() -> &'static Mutex<HashMap<u64, StreamControl>> {
    STREAMS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn import_key_response(key_path: *const c_char, key_content: *const c_char) -> serde_json::Value {
    match import_key(key_path, key_content) {
        Ok(value) => value,
        Err(error) => serde_json::json!({
            "ok": false,
            "error": error,
        }),
    }
}

fn import_key(
    key_path: *const c_char,
    key_content: *const c_char,
) -> Result<serde_json::Value, String> {
    let key_path = required_c_string(key_path, "key_path")?;
    let key_content = required_c_string(key_content, "key_content")?;
    let bytes = parse_key_content(&key_content)?;
    persist_key(Path::new(&key_path), &bytes)?;
    Ok(serde_json::json!({
        "ok": true,
        "operation": "import_key",
        "key_path": key_path,
    }))
}

fn replay_session_response(request_json: *const c_char) -> serde_json::Value {
    match replay_session_request(request_json) {
        Ok(value) => value,
        Err(error) => serde_json::json!({
            "ok": false,
            "error": error,
        }),
    }
}

fn replay_session_request(request_json: *const c_char) -> Result<serde_json::Value, String> {
    let request_json = required_c_string(request_json, "request_json")?;
    let request: serde_json::Value =
        serde_json::from_str(&request_json).map_err(|e| format!("parse request_json: {e}"))?;
    let opts = connection_options_from_request(&request)?;
    let id = required_json_string(&request, "id")?;
    let max_bytes = usize_json_field(&request, "max_bytes")?
        .unwrap_or(DEFAULT_REPLAY_MAX_BYTES)
        .min(MAX_REPLAY_BYTES);
    let value = block_on_ffi_result(move || async move {
        let mut conn = connect(&opts).await?;
        replay_session(&mut conn, &id, Some(max_bytes)).await
    })?;
    Ok(ok_value("replay_session", value))
}

fn connection_options_from_request(
    request: &serde_json::Value,
) -> Result<ConnectionOptions, String> {
    let agent_url = required_json_string(request, "agent_url")?;
    let key_path = required_json_string(request, "key_path")?;
    let quote_verification =
        if bool_json_field(request, "insecure_skip_quote_verify")?.unwrap_or(false) {
            QuoteVerification::InsecureSkip
        } else {
            QuoteVerification::IntelTrustAuthority(IntelTrustAuthority {
                api_key: required_json_string(request, "ita_api_key")?,
                base_url: optional_json_string(request, "ita_base_url")?
                    .unwrap_or_else(|| DEFAULT_ITA_BASE_URL.to_string()),
                jwks_url: optional_json_string(request, "ita_jwks_url")?
                    .unwrap_or_else(|| DEFAULT_ITA_JWKS_URL.to_string()),
                issuer: optional_json_string(request, "ita_issuer")?
                    .unwrap_or_else(|| DEFAULT_ITA_ISSUER.to_string()),
            })
        };

    Ok(ConnectionOptions {
        agent_url,
        key_path: PathBuf::from(key_path),
        quote_verification,
    })
}

fn required_c_string(ptr: *const c_char, name: &str) -> Result<String, String> {
    optional_c_string(ptr)?.ok_or_else(|| format!("{name} is required"))
}

fn optional_c_string(ptr: *const c_char) -> Result<Option<String>, String> {
    if ptr.is_null() {
        return Ok(None);
    }
    let s = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| e.to_string())?
        .to_owned();
    Ok(Some(s))
}

fn required_json_string(request: &serde_json::Value, name: &str) -> Result<String, String> {
    optional_json_string(request, name)?.ok_or_else(|| format!("{name} is required"))
}

fn optional_json_string(request: &serde_json::Value, name: &str) -> Result<Option<String>, String> {
    match request.get(name) {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::String(value)) if value.is_empty() => Ok(None),
        Some(serde_json::Value::String(value)) => Ok(Some(value.to_owned())),
        Some(_) => Err(format!("{name} must be a string")),
    }
}

fn bool_json_field(request: &serde_json::Value, name: &str) -> Result<Option<bool>, String> {
    match request.get(name) {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(format!("{name} must be a boolean")),
    }
}

fn u64_json_field(request: &serde_json::Value, name: &str) -> Result<Option<u64>, String> {
    match request.get(name) {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::Number(value)) => value
            .as_u64()
            .ok_or_else(|| format!("{name} must be an unsigned integer"))
            .map(Some),
        Some(_) => Err(format!("{name} must be an unsigned integer")),
    }
}

fn usize_json_field(request: &serde_json::Value, name: &str) -> Result<Option<usize>, String> {
    Ok(u64_json_field(request, name)?.map(|value| value as usize))
}

fn block_on_ffi<M, F, T>(make_future: M) -> Result<T, String>
where
    M: FnOnce() -> F + Send + 'static,
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let runtime = runtime()?;
    let worker = thread::Builder::new()
        .name("dd-client-ffi".to_string())
        .stack_size(16 * 1024 * 1024)
        .spawn(move || runtime.block_on(make_future()))
        .map_err(|e| format!("spawn async worker: {e}"))?;

    worker
        .join()
        .map_err(|_| "dd-client async worker panicked".to_string())
}

fn block_on_ffi_result<M, F, T, E>(make_future: M) -> Result<T, String>
where
    M: FnOnce() -> F + Send + 'static,
    F: Future<Output = Result<T, E>> + Send + 'static,
    T: Send + 'static,
    E: ToString + Send + 'static,
{
    block_on_ffi(make_future)?.map_err(|e| e.to_string())
}

fn runtime() -> Result<&'static tokio::runtime::Runtime, String> {
    static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, String>> = OnceLock::new();

    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| e.to_owned())
}

fn ok_value(operation: &str, value: serde_json::Value) -> serde_json::Value {
    let mut response = ok_map(operation);
    response.insert("value".to_string(), value);
    serde_json::Value::Object(response)
}

fn ok_map(operation: &str) -> serde_json::Map<String, serde_json::Value> {
    serde_json::Map::from_iter([
        ("ok".to_string(), serde_json::Value::Bool(true)),
        (
            "operation".to_string(),
            serde_json::Value::String(operation.to_string()),
        ),
    ])
}

fn parse_key_content(content: &str) -> Result<[u8; 32], String> {
    let compact: String = content.split_whitespace().collect();
    let hexish = compact.strip_prefix("0x").unwrap_or(&compact);
    let bytes = if hexish.len() == 64 && hexish.bytes().all(|b| b.is_ascii_hexdigit()) {
        hex::decode(hexish).map_err(|e| format!("decode key hex: {e}"))?
    } else {
        let mut decoded = None;
        for engine in [
            &base64::engine::general_purpose::STANDARD,
            &base64::engine::general_purpose::STANDARD_NO_PAD,
            &base64::engine::general_purpose::URL_SAFE,
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
        ] {
            if let Ok(bytes) = engine.decode(&compact) {
                decoded = Some(bytes);
                break;
            }
        }
        decoded.ok_or_else(|| {
            "key_content must be 32 raw bytes encoded as hex or base64".to_string()
        })?
    };

    if bytes.len() != 32 {
        return Err(format!(
            "key_content decoded to {} bytes, expected 32",
            bytes.len()
        ));
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    Ok(key)
}

fn persist_key(path: &Path, bytes: &[u8; 32]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let tmp = path.with_extension("key.tmp");
    std::fs::write(&tmp, bytes).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("chmod {}: {e}", tmp.display()))?;
    }
    std::fs::rename(&tmp, path).map_err(|e| format!("rename {}: {e}", path.display()))?;
    Ok(())
}

fn into_c_string(value: serde_json::Value) -> *mut c_char {
    let text = serde_json::to_string(&value)
        .unwrap_or_else(|e| format!(r#"{{"ok":false,"error":"serialize response: {e}"}}"#));
    CString::new(text)
        .unwrap_or_else(|_| {
            CString::new(r#"{"ok":false,"error":"response contained nul"}"#).unwrap()
        })
        .into_raw()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_key_accepts_hex_content() {
        let dir = tempfile::tempdir().unwrap();
        let key_path = dir.path().join("noise.key");
        let key_path_c = CString::new(key_path.to_string_lossy().as_ref()).unwrap();
        let key_content_c = CString::new("07".repeat(32)).unwrap();

        let value = import_key_response(key_path_c.as_ptr(), key_content_c.as_ptr());

        assert_eq!(value["ok"], true);
        assert_eq!(std::fs::read(key_path).unwrap(), vec![7u8; 32]);
    }

    #[test]
    fn connection_options_requires_ita_key_when_verification_enabled() {
        let request: serde_json::Value = serde_json::json!({
            "agent_url": "https://agent.example.com",
            "key_path": "/tmp/noise.key",
            "insecure_skip_quote_verify": false
        });

        let error = connection_options_from_request(&request).unwrap_err();

        assert!(error.contains("ita_api_key"));
    }
}
