import Foundation
import SwiftUI

// Types referenced here — `SessionHandle`, `BlockObserver`, `FfiBlock`,
// `FfiMode`, `FfiMenuOption`, `keygen`, `KeygenResult` — come from the
// UniFFI-generated `dd-client-ffi` bindings. Generate them with:
//
//   cargo build -p dd-client-ffi --release   # produces the staticlib
//   cargo run -p uniffi-bindgen -- generate \
//     --library target/release/libdd_client_ffi.a --language swift --out-dir apps/ios/Generated
//
// then add Generated/*.swift + the static lib (as an xcframework) to the target.

/// Observable wrapper around a live `SessionHandle`. All interpretation lives in
/// Rust; this just mirrors the block snapshot into SwiftUI on change.
@MainActor
final class SessionModel: ObservableObject {
    @Published var blocks: [FfiBlock] = []
    @Published var mode: FfiMode = .watch
    @Published var status: String = "Not connected"
    @Published var connected = false
    @Published var connecting = false

    private var handle: SessionHandle?
    private var observer: ChangeObserver?

    func connect(agentUrl: String, keyPath: String, sessionId: String, insecure: Bool) {
        connecting = true
        status = "Connecting…"
        Task.detached { [weak self] in
            do {
                // attach() blocks on the Noise handshake — off the main actor.
                let handle = try SessionHandle.attach(
                    agentUrl: agentUrl,
                    keyPath: keyPath,
                    sessionId: sessionId,
                    insecureSkipQuoteVerify: insecure,
                    jwksUrl: "https://portal.trustauthority.intel.com/certs",
                    issuer: "https://portal.trustauthority.intel.com"
                )
                await self?.onAttached(handle)
            } catch {
                await self?.onFailed(error)
            }
        }
    }

    private func onAttached(_ handle: SessionHandle) {
        self.handle = handle
        let observer = ChangeObserver(model: self)
        self.observer = observer
        handle.subscribe(observer: observer)
        self.mode = handle.mode()
        self.connecting = false
        self.connected = true
        self.status = "Connected"
        reload()
    }

    private func onFailed(_ error: Error) {
        self.connecting = false
        self.status = "Failed: \(error)"
    }

    func reload() {
        blocks = handle?.blocks() ?? []
    }

    func setMode(_ newMode: FfiMode) {
        handle?.setMode(mode: newMode)
        mode = newMode
    }

    /// Send text to the session (ignored by the engine in Watch — read-only).
    func send(_ text: String) {
        handle?.sendText(text: text)
    }

    /// Pick a menu option: send its hotkey when known, else its 1-based number.
    func pick(option: FfiMenuOption, index: Int) {
        if let hotkey = option.hotkey {
            send(hotkey)
        } else {
            send(String(index + 1))
        }
    }

    func disconnect() {
        handle?.close()
        handle = nil
        observer = nil
        connected = false
        status = "Disconnected"
        blocks = []
    }
}

/// Bridges the Rust `BlockObserver` callback onto the main actor.
final class ChangeObserver: BlockObserver {
    weak var model: SessionModel?
    init(model: SessionModel) { self.model = model }

    func onChanged() {
        Task { @MainActor [weak model] in model?.reload() }
    }
}
