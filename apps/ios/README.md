# iOS Client

The iOS client should be a native SwiftUI app backed by the Rust client core.

Initial split:

- SwiftUI owns screens, navigation, notifications, Keychain access, and iOS
  lifecycle.
- `dd-client-core` owns protocol behavior: pairing keys, quote verification,
  direct agent Noise transport, session RPCs, and PTY bytes.
- `dd-client-ffi` exposes a C-compatible bridge that can be linked into an
  Xcode target as a static library.

First screen to build:

1. Generate or load a device key from Keychain-backed storage.
2. Display the public key and CP enrollment URL.
3. Open the enrollment URL in an authenticated browser session.
4. After enrollment, list routed agents and connect directly to the selected
   agent over Noise.

The iOS app should not embed a browser shell or PWA. It should be a native
client using the same core as the CLI.

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

