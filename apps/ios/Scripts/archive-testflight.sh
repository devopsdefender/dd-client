#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="DevOpsDefender.xcodeproj"
SCHEME="DevOpsDefender"
CONFIGURATION="${CONFIGURATION:-Release}"
DEVELOPMENT_TEAM="${DD_DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${DD_BUNDLE_ID:-}"
MARKETING_VERSION="${DD_MARKETING_VERSION:-0.1}"
BUILD_NUMBER="${DD_BUILD_NUMBER:-1}"
BUILD_DIR="${DD_IOS_BUILD_DIR:-$PWD/build}"
ARCHIVE_PATH="${DD_ARCHIVE_PATH:-$BUILD_DIR/DevOpsDefender.xcarchive}"
EXPORT_PATH="${DD_EXPORT_PATH:-$BUILD_DIR/TestFlight}"
ASC_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-${DD_APP_STORE_CONNECT_API_KEY_PATH:-}}"
ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-${DD_APP_STORE_CONNECT_API_KEY_ID:-}}"
ASC_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-${DD_APP_STORE_CONNECT_API_ISSUER_ID:-}}"
INTERNAL_ONLY="${DD_TESTFLIGHT_INTERNAL_ONLY:-true}"

require_env() {
  if [ -z "${!1:-}" ]; then
    echo "error: $1 is required" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: $1 not found" >&2
    exit 1
  fi
}

require_env DEVELOPMENT_TEAM
require_env BUNDLE_ID
require_command xcodebuild
require_command xcodegen

AUTH_ARGS=()
if [ -n "$ASC_KEY_PATH$ASC_KEY_ID$ASC_ISSUER_ID" ]; then
  require_env ASC_KEY_PATH
  require_env ASC_KEY_ID
  require_env ASC_ISSUER_ID
  AUTH_ARGS=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

if [ "$INTERNAL_ONLY" = "true" ] || [ "$INTERNAL_ONLY" = "YES" ] || [ "$INTERNAL_ONLY" = "1" ]; then
  INTERNAL_ONLY_PLIST=true
else
  INTERNAL_ONLY_PLIST=false
fi

xcodegen generate

mkdir -p Config "$BUILD_DIR" "$EXPORT_PATH"
cat > Config/Signing.local.xcconfig <<EOF
DEVELOPMENT_TEAM = $DEVELOPMENT_TEAM
DD_PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID
DD_MARKETING_VERSION = $MARKETING_VERSION
DD_BUILD_NUMBER = $BUILD_NUMBER
EOF

xcodebuild \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  DD_PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  DD_MARKETING_VERSION="$MARKETING_VERSION" \
  DD_BUILD_NUMBER="$BUILD_NUMBER" \
  archive

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.TestFlight.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>testFlightInternalTestingOnly</key>
  <$INTERNAL_ONLY_PLIST/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

xcodebuild \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}" \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"
