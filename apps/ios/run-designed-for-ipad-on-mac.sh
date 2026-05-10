#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="DevOpsDefender.xcodeproj"
SCHEME="DevOpsDefender"
BUNDLE_ID="com.devopsdefender.client"
MAC_DESTINATION_ID="${DD_IOS_MAC_DEVICE_ID:-}"
COREDEVICE_ID="${DD_COREDEVICE_ID:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEVELOPMENT_TEAM="${DD_DEVELOPMENT_TEAM:-}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode and select it with xcode-select." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found. Install Xcode command line tools." >&2
  exit 1
fi

if [ ! -d "$PROJECT" ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: $PROJECT is missing and xcodegen is not installed." >&2
    echo "install: brew install xcodegen" >&2
    exit 1
  fi
  xcodegen generate
fi

if [ -z "$MAC_DESTINATION_ID" ]; then
  MAC_DESTINATION_ID="$(
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
      | sed -n 's/.*platform:macOS.*variant:Designed for \[iPad,iPhone\].*id:\([^,}]*\).*/\1/p' \
      | head -n 1
  )"
fi

if [ -z "$MAC_DESTINATION_ID" ]; then
  echo "error: could not find a 'My Mac (Designed for iPad)' destination." >&2
  echo "run: xcodebuild -project $PROJECT -scheme $SCHEME -showdestinations" >&2
  echo "then retry with: DD_IOS_MAC_DEVICE_ID=<id> $0" >&2
  exit 1
fi

if [ -z "$DEVELOPMENT_TEAM" ]; then
  DEVELOPMENT_TEAM="$(
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "platform=macOS,id=$MAC_DESTINATION_ID" \
      -showBuildSettings 2>/dev/null \
      | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' \
      | head -n 1
  )"
fi

if [ -z "$DEVELOPMENT_TEAM" ]; then
  echo "error: DEVELOPMENT_TEAM is required to install/run an iOS app on Mac." >&2
  echo "retry: DD_DEVELOPMENT_TEAM=<apple-team-id> $0" >&2
  echo "find team ids in Xcode Accounts or with: security find-identity -v -p codesigning" >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,id=$MAC_DESTINATION_ID" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  build

DERIVED_DATA_DIR="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings \
    -json \
    | plutil -extract 0.buildSettings.BUILT_PRODUCTS_DIR raw -o - -
)"
APP="$DERIVED_DATA_DIR/DevOpsDefender.app"

if [ ! -d "$APP" ]; then
  echo "error: built app not found at $APP" >&2
  exit 1
fi

if [ -n "$COREDEVICE_ID" ]; then
  xcrun devicectl device install app --device "$COREDEVICE_ID" "$APP"
  xcrun devicectl device process launch --device "$COREDEVICE_ID" "$BUNDLE_ID"
  exit 0
fi

cat <<EOF
Built signed iOS app for "My Mac (Designed for iPad)" at:
$APP

Xcode exposes the local Mac compatibility destination to xcodebuild, but it is
not listed by CoreDevice/devicectl. To run it on this Mac, open:

  $PROJECT

Then select "My Mac (Designed for iPad)" and press Run.

For a physical iPhone or iPad, pass a CoreDevice id from:

  xcrun devicectl list devices

Example:

  DD_DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM DD_COREDEVICE_ID=<device-id> $0
EOF
