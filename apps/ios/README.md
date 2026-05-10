# iOS Client

Native SwiftUI client backed by `dd-client-core` through `dd-client-ffi`.
Swift owns the UI and lifecycle; Rust owns direct Noise transport, quote
verification, recipes, sessions, replay, and attach/write/detach primitives.

The current vertical slice targets PR preview testing against:

```bash
https://dd-pr-261-api-23bf4739-7737-483f-9256-1d184cbb7fab.devopsdefender.com
```

The app defaults to that URL and, on simulator or "Designed for iPad on Mac",
tries `~/.config/devopsdefender/noise.key`. On sandboxed installs, use the
"Use app support key path" button and paste/import the Noise key content.

## App Workflow

- Toggle "Dev/test: skip TDX quote verification" for PR previews. This maps to
  the CLI `--insecure-skip-quote-verify` path.
- Tap "Load recipes" to call Rust for the recipe list.
- Tap "List sessions" to call Rust for current sessions.
- Tap "Create shell session" to create a session with recipe `shell`.
- Select a session, then use "Replay transcript" or "Attach / refresh output".
- Use the zoom stepper for larger transcript text when reading output on mobile.
- Use quick write controls for common agent prompts: `1`, `2`, `Enter`, or a
  short custom line. Attach/write/detach does not close the remote session.
- Enable session notifications to get a local notification when a newly listed
  session appears while the app is active.

This app intentionally does not embed a browser shell or fallback web terminal.

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

## Build For iOS Simulator

Use an available simulator destination from `xcodebuild -showdestinations`.
Example compile command:

```bash
cd apps/ios
xcodebuild \
  -project DevOpsDefender.xcodeproj \
  -scheme DevOpsDefender \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/dd-client-xcode-derived \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Build For "Designed For iPad On Mac"

Compile without signing:

```bash
cd apps/ios
xcodebuild -project DevOpsDefender.xcodeproj -scheme DevOpsDefender -showdestinations
xcodebuild \
  -project DevOpsDefender.xcodeproj \
  -scheme DevOpsDefender \
  -configuration Debug \
  -destination 'platform=macOS,id=<my-mac-designed-for-ipad-id>' \
  -derivedDataPath /private/tmp/dd-client-xcode-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build/sign for local "My Mac (Designed for iPad)":

```bash
cd apps/ios
DD_DEVELOPMENT_TEAM=<apple-team-id> ./run-designed-for-ipad-on-mac.sh
```

`xcodebuild` can build the local Mac compatibility destination, but
`devicectl` does not list that destination. After the script builds the signed
app, open `DevOpsDefender.xcodeproj`, select "My Mac (Designed for iPad)", and
press Run.

For a physical iPhone or iPad, install and launch with CoreDevice:

```bash
cd apps/ios
xcrun devicectl list devices
DD_DEVELOPMENT_TEAM=<apple-team-id> DD_COREDEVICE_ID=<device-id> ./run-designed-for-ipad-on-mac.sh
```
