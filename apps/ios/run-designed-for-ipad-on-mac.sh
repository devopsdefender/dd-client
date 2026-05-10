#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="DevOpsDefender.xcodeproj"
SCHEME="DevOpsDefender"
BUNDLE_ID="com.devopsdefender.client"
DEVICE_ID="${DD_IOS_MAC_DEVICE_ID:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"

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

if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
      | sed -n 's/.*platform:macOS.*variant:Designed for \[iPad,iPhone\].*id:\([^,}]*\).*/\1/p' \
      | head -n 1
  )"
fi

if [ -z "$DEVICE_ID" ]; then
  echo "error: could not find a 'My Mac (Designed for iPad)' destination." >&2
  echo "run: xcodebuild -project $PROJECT -scheme $SCHEME -showdestinations" >&2
  echo "then retry with: DD_IOS_MAC_DEVICE_ID=<id> $0" >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,id=$DEVICE_ID" \
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

xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
