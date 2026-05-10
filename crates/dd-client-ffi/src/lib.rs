use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use dd_client_core::{
    attach_session_exchange, connect, create_session, list_recipes, list_sessions, replay_session,
    session_id, ConnectionOptions, CreateSessionRequest, IntelTrustAuthority, QuoteVerification,
};

const DEFAULT_ITA_BASE_URL: &str = "https://api.trustauthority.intel.com";
const DEFAULT_ITA_JWKS_URL: &str = "https://portal.trustauthority.intel.com/certs";
const DEFAULT_ITA_ISSUER: &str = "https://portal.trustauthority.intel.com";
const DEFAULT_ATTACH_MAX_BYTES: usize = 128 * 1024;
const MAX_ATTACH_BYTES: usize = 1024 * 1024;
const DEFAULT_ATTACH_IDLE_TIMEOUT_MS: u64 = 1200;

#[no_mangle]
pub extern "C" fn dd_client_keygen(
    key_path: *const c_char,
    cp_url: *const c_char,
    label: *const c_char,
) -> *mut c_char {
    let result = keygen_response(key_path, cp_url, label);
    into_c_string(result)
}

#[no_mangle]
pub extern "C" fn dd_client_agent_request(request_json: *const c_char) -> *mut c_char {
    let result = agent_request_response(request_json);
    into_c_string(result)
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

fn keygen_response(
    key_path: *const c_char,
    cp_url: *const c_char,
    label: *const c_char,
) -> serde_json::Value {
    match keygen(key_path, cp_url, label) {
        Ok(value) => value,
        Err(error) => serde_json::json!({
            "ok": false,
            "error": error,
        }),
    }
}

fn keygen(
    key_path: *const c_char,
    cp_url: *const c_char,
    label: *const c_char,
) -> Result<serde_json::Value, String> {
    let key_path = required_c_string(key_path, "key_path")?;
    let cp_url = optional_c_string(cp_url)?;
    let label = optional_c_string(label)?;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let pubkey_hex = runtime
        .block_on(dd_client_core::public_key_hex(Path::new(&key_path)))
        .map_err(|e| e.to_string())?;
    let enrollment_url = match (cp_url.as_deref(), label.as_deref()) {
        (Some(cp_url), Some(label)) => {
            Some(dd_client_core::enrollment_url(cp_url, &pubkey_hex, label))
        }
        _ => None,
    };

    Ok(serde_json::json!({
        "ok": true,
        "pubkey_hex": pubkey_hex,
        "enrollment_url": enrollment_url,
    }))
}

fn agent_request_response(request_json: *const c_char) -> serde_json::Value {
    match agent_request(request_json) {
        Ok(value) => value,
        Err(error) => serde_json::json!({
            "ok": false,
            "error": error,
        }),
    }
}

fn agent_request(request_json: *const c_char) -> Result<serde_json::Value, String> {
    let request_json = required_c_string(request_json, "request_json")?;
    let request: serde_json::Value =
        serde_json::from_str(&request_json).map_err(|e| format!("parse request_json: {e}"))?;
    let operation = required_json_string(&request, "operation")?;

    match operation.as_str() {
        "import_key" => import_key_request(&request),
        "recipes" | "list_recipes" => {
            let opts = connection_options_from_request(&request)?;
            let runtime = runtime()?;
            let value = runtime
                .block_on(async {
                    let mut conn = connect(&opts).await?;
                    list_recipes(&mut conn).await
                })
                .map_err(|e| e.to_string())?;
            Ok(ok_value("recipes", value))
        }
        "sessions" | "list_sessions" => {
            let opts = connection_options_from_request(&request)?;
            let runtime = runtime()?;
            let value = runtime
                .block_on(async {
                    let mut conn = connect(&opts).await?;
                    list_sessions(&mut conn).await
                })
                .map_err(|e| e.to_string())?;
            Ok(ok_value("sessions", value))
        }
        "create_session" => {
            let opts = connection_options_from_request(&request)?;
            let create_request = CreateSessionRequest {
                recipe: optional_json_string(&request, "recipe")?,
                name: optional_json_string(&request, "name")?,
                command: optional_json_string(&request, "command")?,
            };
            let runtime = runtime()?;
            let value = runtime
                .block_on(async {
                    let mut conn = connect(&opts).await?;
                    create_session(&mut conn, &create_request).await
                })
                .map_err(|e| e.to_string())?;
            let mut response = ok_map("create_session");
            if let Ok(id) = session_id(&value) {
                response.insert("session_id".to_string(), serde_json::Value::String(id));
            }
            response.insert("value".to_string(), value);
            Ok(serde_json::Value::Object(response))
        }
        "replay_session" => {
            let opts = connection_options_from_request(&request)?;
            let id = required_json_string(&request, "id")?;
            let runtime = runtime()?;
            let value = runtime
                .block_on(async {
                    let mut conn = connect(&opts).await?;
                    replay_session(&mut conn, &id).await
                })
                .map_err(|e| e.to_string())?;
            Ok(ok_value("replay_session", value))
        }
        "attach_exchange" | "attach_snapshot" => {
            let opts = connection_options_from_request(&request)?;
            let id = required_json_string(&request, "id")?;
            let input = optional_json_string(&request, "input")?.unwrap_or_default();
            let max_bytes = usize_json_field(&request, "max_bytes")?
                .unwrap_or(DEFAULT_ATTACH_MAX_BYTES)
                .min(MAX_ATTACH_BYTES);
            let idle_timeout_ms = u64_json_field(&request, "idle_timeout_ms")?
                .unwrap_or(DEFAULT_ATTACH_IDLE_TIMEOUT_MS)
                .clamp(100, 10_000);
            let runtime = runtime()?;
            let bytes = runtime
                .block_on(async {
                    let conn = connect(&opts).await?;
                    attach_session_exchange(
                        conn,
                        &id,
                        input.as_bytes(),
                        max_bytes,
                        Duration::from_millis(idle_timeout_ms),
                    )
                    .await
                })
                .map_err(|e| e.to_string())?;
            let mut response = ok_map("attach_exchange");
            response.insert(
                "text".to_string(),
                serde_json::Value::String(String::from_utf8_lossy(&bytes).into_owned()),
            );
            response.insert(
                "bytes_base64".to_string(),
                serde_json::Value::String(base64::engine::general_purpose::STANDARD.encode(&bytes)),
            );
            response.insert(
                "truncated".to_string(),
                serde_json::Value::Bool(bytes.len() >= max_bytes),
            );
            Ok(serde_json::Value::Object(response))
        }
        _ => Err(format!("unsupported operation: {operation}")),
    }
}

fn import_key_request(request: &serde_json::Value) -> Result<serde_json::Value, String> {
    let key_path = required_json_string(request, "key_path")?;
    let key_content = required_json_string(request, "key_content")?;
    let bytes = parse_key_content(&key_content)?;
    persist_key(Path::new(&key_path), &bytes)?;
    Ok(serde_json::json!({
        "ok": true,
        "operation": "import_key",
        "key_path": key_path,
    }))
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

fn runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())
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
    fn keygen_returns_enrollment_url() {
        let dir = tempfile::tempdir().unwrap();
        let key_path =
            CString::new(dir.path().join("noise.key").to_string_lossy().as_ref()).unwrap();
        let cp_url = CString::new("https://cp.example.com").unwrap();
        let label = CString::new("ios phone").unwrap();

        let value = keygen_response(key_path.as_ptr(), cp_url.as_ptr(), label.as_ptr());

        assert_eq!(value["ok"], true);
        assert!(value["pubkey_hex"].as_str().unwrap().len() == 64);
        assert_eq!(
            value["enrollment_url"],
            "https://cp.example.com/admin/enroll?pubkey=".to_string()
                + value["pubkey_hex"].as_str().unwrap()
                + "&label=ios%20phone"
        );
    }

    #[test]
    fn keygen_rejects_missing_key_path() {
        let value = keygen_response(std::ptr::null(), std::ptr::null(), std::ptr::null());

        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().unwrap().contains("key_path"));
    }

    #[test]
    fn agent_request_rejects_unknown_operation() {
        let request = CString::new(r#"{"operation":"bogus"}"#).unwrap();

        let value = agent_request_response(request.as_ptr());

        assert_eq!(value["ok"], false);
        assert!(value["error"]
            .as_str()
            .unwrap()
            .contains("unsupported operation"));
    }

    #[test]
    fn import_key_accepts_hex_content() {
        let dir = tempfile::tempdir().unwrap();
        let key_path = dir.path().join("noise.key");
        let request = CString::new(format!(
            r#"{{"operation":"import_key","key_path":"{}","key_content":"{}"}}"#,
            key_path.display(),
            "07".repeat(32)
        ))
        .unwrap();

        let value = agent_request_response(request.as_ptr());

        assert_eq!(value["ok"], true);
        assert_eq!(std::fs::read(key_path).unwrap(), vec![7u8; 32]);
    }

    #[test]
    fn connection_options_requires_ita_key_when_verification_enabled() {
        let request: serde_json::Value = serde_json::json!({
            "operation": "recipes",
            "agent_url": "https://agent.example.com",
            "key_path": "/tmp/noise.key",
            "insecure_skip_quote_verify": false
        });

        let error = connection_options_from_request(&request).unwrap_err();

        assert!(error.contains("ita_api_key"));
    }
}
