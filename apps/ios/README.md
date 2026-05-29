# iOS Client

The iOS client should be a native SwiftUI app backed by the Rust client core.

Split:

- SwiftUI owns screens, navigation, notifications, Keychain access, and iOS
  lifecycle.
- `dd-client-session` owns interpretation: blocks, the floor/agent derivers,
  view modes, and history decryption — shared verbatim with the CLI.
- `dd-client-core` owns protocol behavior: pairing keys, quote verification
  (verify-only, no Intel account), Noise transport, session RPCs, PTY bytes.
- `dd-client-ffi` exposes all of the above over **UniFFI** (Swift + Kotlin
  generated from one Rust surface) — no hand-written C.

The app is a renderer for the structured chat document the engine produces:
`SessionHandle.blocks()` returns typed `FfiBlock`s, a `BlockObserver` fires on
change, and `setMode`/`sendText` drive Watch ⇄ Interact ⇄ Raw. No protocol,
crypto, or terminal-interpretation logic lives in Swift. See `SessionModel.swift`
and `ContentView.swift`.

## Generating the UniFFI bindings

The Swift in this folder references types (`SessionHandle`, `FfiBlock`,
`FfiMode`, `keygen`, …) emitted by UniFFI. Generate them before building:

```bash
# from the repo root
cargo build -p dd-client-ffi --release
cargo run -p dd-client-ffi --bin uniffi-bindgen -- generate \
  --library target/release/libdd_client_ffi.dylib \
  --language swift --out-dir apps/ios/Generated
```

Then add `apps/ios/Generated/*.swift` to the target and link the Rust static
library as an `xcframework` (build `aarch64-apple-ios` + the simulator/macABI
triples and `xcodebuild -create-xcframework`). The generated `*.modulemap`
header path is wired via the xcframework.

> The Rust FFI crate is compile/clippy/test-verified on Linux. The binding
> generation and the iOS build require the Apple toolchain (Xcode), which isn't
> available in CI here — run the steps above on macOS.

First-run flow:

1. Generate or load the device key (`keygen`), Keychain-backed.
2. Show the pubkey + CP enrollment URL; enroll in an authenticated browser.
3. After enrollment, attach to a session and render its block document.

The iOS app does not embed a browser shell or PWA.

macOS testing target:

- The first app target should run on Apple Silicon Macs through iOS app
  compatibility mode, shown by Xcode as "Designed for iPhone/iPad".
- Do not fork the first slice into a Catalyst UI. Keep one iOS app surface and
  make macOS compatibility a target setting.
- The project should keep `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES` and
  target both iPhone and iPad device families.

Generate/open the starter project with XcodeGen:

```bash
cd apps/ios
xcodegen generate
open DevOpsDefender.xcodeproj
```

Run the iOS app on Apple Silicon macOS through iOS compatibility mode:

```bash
cd apps/ios
chmod +x run-designed-for-ipad-on-mac.sh
./run-designed-for-ipad-on-mac.sh
```

If destination discovery fails, pass the `My Mac (Designed for iPad)` id from
`xcodebuild -project DevOpsDefender.xcodeproj -scheme DevOpsDefender -showdestinations`:

```bash
DD_IOS_MAC_DEVICE_ID=00008122-000121C20AF1001C ./run-designed-for-ipad-on-mac.sh
```
