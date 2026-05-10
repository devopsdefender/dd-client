# iOS Client

Native SwiftUI companion for `dd-client` CLI sessions.

The desktop CLI owns agent selection, session creation, enrollment, and full
terminal attach. The iOS app only opens a desktop-generated session link, loads
bounded transcript history, and follows the live transcript.

## Desktop Flow

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
  --id "$SESSION_ID" \
  --include-key
```

Open the printed `devopsdefender://session?...` link on iOS, or render the QR
with the printed `qrencode` command. With `--include-key`, the link contains the
Noise private key and the app imports it before loading history and following
the transcript; treat the link or QR as secret.

## Key Import Fallback

Prefer `--include-key` so the link is self-contained. If you omit it, the app
can only connect after a key has already been imported into its Application
Support directory.

```bash
xxd -p -c 256 "$HOME/.config/devopsdefender/noise.key" | pbcopy
```

## App Workflow

- Open a `devopsdefender://session?...` link or scan its QR code.
- The app imports the embedded key when present.
- The app loads recent transcript history, then keeps following live output.

The app intentionally does not create sessions, list recipes, browse agents,
send input, or take over terminal control.

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
