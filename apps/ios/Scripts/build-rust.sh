#!/bin/sh
set -eu

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT=$(cd "$SRCROOT/../.." && pwd)
else
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
fi

PLATFORM="${PLATFORM_NAME:-iphonesimulator}"
CONFIGURATION="${CONFIGURATION:-Debug}"
ARCHS_TO_BUILD="${ARCHS:-${CURRENT_ARCH:-arm64}}"
if [ -n "${TARGET_TEMP_DIR:-}" ]; then
  OUT_DIR="$TARGET_TEMP_DIR/rust"
else
  OUT_DIR="$REPO_ROOT/target/ios-universal/$PLATFORM"
fi

if [ -z "${CARGO_TARGET_DIR:-}" ]; then
  if [ -n "${DERIVED_FILE_DIR:-}" ]; then
    CARGO_TARGET_DIR="$DERIVED_FILE_DIR/rust-cargo-target"
  else
    CARGO_TARGET_DIR="$REPO_ROOT/target"
  fi
  export CARGO_TARGET_DIR
fi

if [ "$CONFIGURATION" = "Release" ]; then
  PROFILE_ARG="--release"
  PROFILE_DIR="release"
else
  PROFILE_ARG=""
  PROFILE_DIR="debug"
fi

mkdir -p "$OUT_DIR"

# Xcode exports an iOS SDKROOT, but Cargo build scripts are host binaries.
# Use the macOS SDK for those host links while Rust still targets iOS below.
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT

libs=""
for arch in $ARCHS_TO_BUILD; do
  case "$PLATFORM:$arch" in
    iphoneos:arm64)
      rust_target="aarch64-apple-ios"
      ;;
    iphonesimulator:arm64)
      rust_target="aarch64-apple-ios-sim"
      ;;
    iphonesimulator:x86_64)
      rust_target="x86_64-apple-ios"
      ;;
    *)
      echo "Unsupported Rust target for PLATFORM_NAME=$PLATFORM arch=$arch" >&2
      exit 1
      ;;
  esac

  if ! rustup target list --installed | grep -qx "$rust_target"; then
    echo "Missing Rust target $rust_target. Install it with: rustup target add $rust_target" >&2
    exit 1
  fi

  cargo build -p dd-client-ffi --lib --target "$rust_target" $PROFILE_ARG
  lib="$CARGO_TARGET_DIR/$rust_target/$PROFILE_DIR/libdd_client_ffi.a"
  if [ ! -f "$lib" ]; then
    echo "Rust library was not produced at $lib" >&2
    exit 1
  fi
  libs="$libs $lib"
done

set -- $libs
if [ "$#" -eq 1 ]; then
  cp "$1" "$OUT_DIR/libdd_client_ffi.a"
else
  lipo -create "$@" -output "$OUT_DIR/libdd_client_ffi.a"
fi
