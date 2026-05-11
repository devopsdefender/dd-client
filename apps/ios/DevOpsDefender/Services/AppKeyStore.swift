import Foundation

/// Owns the iOS device's persistent Noise key — distinct from the
/// mobile-link key (`noise.key`) so the desktop-handoff flow and the
/// fleet flow never overwrite each other's material.
///
/// On first use, calls `dd_client_ensure_key` (FFI) which generates a
/// fresh X25519 keypair if the file is missing. Subsequent calls just
/// re-derive the public key from the existing private key, so it's
/// idempotent.
struct AppKeyStore {
    static let shared = AppKeyStore()

    /// File path the iOS device's own Noise private key lives at.
    var keyPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("devopsdefender", isDirectory: true)
            .appendingPathComponent("ios.key")
            .path
    }

    /// Ensure the iOS device key exists and return its hex-encoded public key.
    @discardableResult
    func ensurePubkeyHex() throws -> String {
        let path = keyPath
        let response = keyPath.withCString { _ in
            dd_client_ensure_key(path)
        }
        guard let response else {
            throw AppKeyStoreError.message("ensure_key returned null")
        }
        defer { dd_client_string_free(response) }
        let json = String(cString: response)
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppKeyStoreError.message("failed to decode ensure_key response: \(json)")
        }
        if let ok = object["ok"] as? Bool, ok,
           let pubkey = object["pubkey_hex"] as? String, !pubkey.isEmpty {
            return pubkey
        }
        let detail = object["error"] as? String ?? json
        throw AppKeyStoreError.message(detail)
    }
}

enum AppKeyStoreError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
