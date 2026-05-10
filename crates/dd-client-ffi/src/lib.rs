use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;

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
}
