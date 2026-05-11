# iOS Client

Native SwiftUI companion for `dd-client` CLI sessions. Two entry paths:

1. **Mobile link from desktop CLI** — desktop generates a one-shot
   `devopsdefender://session?...` link with an embedded Noise key.
2. **Fleet discovery on device** — sign in with GitHub against the control
   plane at `app.devopsdefender.com`, browse the agents and sessions the
   authenticated user has access to. The iOS device holds its own Noise key
   distinct from the mobile-link key.

The app is an interactive client, not a passive viewer: keystrokes flow back
through the existing Noise channel, the keyboard surface adapts to the running
agent (Claude Code option menus, yes/no confirmations, raw shell), and ANSI
colors render with a proper SGR parser. The mobile-link and fleet paths
coexist; the launch screen routes between them.

## Desktop Flow (mobile-link path)

Start or reattach a CLI session first:

```bash
cd ~/src/dd-client

cargo run -p dd-client -- shell \
  --url "$AGENT_URL" \
  --key "$HOME/.config/devopsdefender/noise.key" \
  --insecure-skip-quote-verify \
  --recipe codex-podman \
  --name "dogfood codex"
```

Detach without closing the session with `Ctrl-]`, then list sessions if needed:

```bash
cargo run -p dd-client -- sessions \
  --url "$AGENT_URL" \
  --key "$HOME/.config/devopsdefender/noise.key" \
  --insecure-skip-quote-verify
```

Generate the iOS link:

```bash
cargo run -p dd-client -- mobile-link \
  --url "$AGENT_URL" \
  --key "$HOME/.config/devopsdefender/noise.key" \
  --id "$SESSION_ID"
```

Open the printed `devopsdefender://session?...` link on iOS, or render the QR
with the printed `qrencode` command. The link contains the Noise private key
and the app imports it; treat the link or QR as secret.

## Fleet Flow (GitHub sign-in path)

Cold-launch the iOS app and tap **Sign in with GitHub**. The app:

1. Ensures a persistent iOS device key exists at
   `Application Support/devopsdefender/ios.key` (X25519, generated via the
   `dd_client_ensure_key` FFI on first launch).
2. Opens an `ASWebAuthenticationSession` against
   `https://app.devopsdefender.com/oauth/ios/start?pubkey=<hex>&label=<device>`.
3. The control plane runs the GitHub OAuth dance, records the
   user ↔ pubkey ↔ label binding, mints a bearer token, and 302s back to
   `devopsdefender://oauth/callback?token=<token>`.
4. The app stores the bearer in Keychain and calls
   `GET /api/v1/agents` for the user's agent list.
5. Tap an agent → `dd_client_list_sessions` enumerates sessions on that agent
   over Noise. Tap a session → the existing keyboard/transcript surface
   engages.

The fleet flow depends on three CP endpoints that live in `devopsdefender/dd`
(tracked at https://github.com/devopsdefender/dd/issues/266) plus agent-side
polling of authorized pubkeys from the CP.

## Prerequisites

```bash
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

On Intel simulator hosts, also install:

```bash
rustup target add x86_64-apple-ios
```

## Generate Project

```bash
cd apps/ios
xcodegen generate
open DevOpsDefender.xcodeproj
```

The Xcode project is generated from `project.yml`. Keep
`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES` and
`SUPPORTS_MACCATALYST = NO`; this target is iOS compatibility mode, not
Catalyst.

## CI And TestFlight

### Xcode Cloud (planned)

Xcode Cloud is the target CI/CD for this app. It runs on Apple infrastructure,
integrates directly with App Store Connect, automates signing, and removes the
need to manage App Store Connect API keys as repo secrets. The existing
`Build Rust FFI` script phase in `project.yml` runs unchanged under Xcode
Cloud.

To set it up:

1. Open `DevOpsDefender.xcodeproj` in Xcode.
2. **Product → Xcode Cloud → Create Workflow**.
3. Create two workflows:
   - **PR build** — start condition: pull request to `main`. Actions: Build
     (Any iOS Device, no archive). No post-actions.
   - **TestFlight build** — start condition: tag matching `ios-v*`. Actions:
     Archive (iOS), TestFlight Internal Distribution.
4. Environment variables on both: `DD_PRODUCT_BUNDLE_IDENTIFIER`,
   `DD_DEVELOPMENT_TEAM`, `DD_MARKETING_VERSION`. Rust toolchain installs
   in the `Scripts/build-rust.sh` prebuild script so no extra Xcode Cloud
   env is needed.

Once Xcode Cloud is green, retire `.github/workflows/ios.yml` and
`.github/workflows/testflight.yml`. Rust-side CI (cargo test/fmt/clippy on
the workspace) stays on GitHub Actions because Xcode Cloud only runs Apple
builds.

### Legacy GitHub Actions (currently active)

Pull requests run `.github/workflows/ios.yml`, which generates the project
and builds the iOS simulator app without code signing.

TestFlight uploads are manual from `.github/workflows/testflight.yml`.
Configure the `testflight` GitHub environment with:

```bash
gh secret set APPLE_TEAM_ID --env testflight
gh secret set APP_STORE_CONNECT_API_KEY_ID --env testflight
gh secret set APP_STORE_CONNECT_API_ISSUER_ID --env testflight
gh secret set APP_STORE_CONNECT_API_PRIVATE_KEY --env testflight < AuthKey_XXXX.p8
```

Then run the `TestFlight` workflow and set the App Store Connect bundle id.
The workflow uses the GitHub run number as `CFBundleVersion` and uploads as
an internal-only TestFlight build by default.
