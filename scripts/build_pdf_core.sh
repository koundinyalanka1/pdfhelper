#!/usr/bin/env bash
#
# Build the native PDF core for one or more platforms.
#
# flutter_pdf_core is vendored as a git submodule and ships Rust source only,
# so this has to run once before the app will do anything with a PDF. The
# output lands inside the submodule where Gradle / CocoaPods pick it up
# automatically:
#
#   android  -> packages/flutter_pdf_core/android/src/main/jniLibs/**/libpdf_ffi.so
#   ios      -> packages/flutter_pdf_core/ios/Frameworks/PdfFfi.xcframework
#   macos    -> packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib
#
# Usage:
#   ./scripts/build_pdf_core.sh              # every platform this host can build
#   ./scripts/build_pdf_core.sh android
#   ./scripts/build_pdf_core.sh ios macos
#   ./scripts/build_pdf_core.sh test         # run the Rust test suite only
#
# Prerequisites:
#   rustup                       https://rustup.rs
#   android: cargo install cargo-ndk
#            rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#            ANDROID_NDK_HOME set (or an NDK under $ANDROID_HOME/ndk)
#   ios:     rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#   macos:   rustup target add aarch64-apple-darwin x86_64-apple-darwin

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$REPO_ROOT/packages/flutter_pdf_core"

if [[ ! -f "$CORE/pubspec.yaml" ]]; then
  echo "error: packages/flutter_pdf_core is empty."
  echo "       Run: git submodule update --init --recursive"
  exit 1
fi

# rustup installs here but does not always end up on a non-login shell's PATH.
if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust from https://rustup.rs and retry."
  exit 1
fi

# Locate an NDK if the caller did not point at one.
find_ndk() {
  [[ -n "${ANDROID_NDK_HOME:-}" ]] && return 0
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  [[ -d "$sdk/ndk" ]] || return 1
  # Highest version wins.
  local latest
  latest="$(ls -1 "$sdk/ndk" | sort -V | tail -1)"
  [[ -n "$latest" ]] || return 1
  export ANDROID_NDK_HOME="$sdk/ndk/$latest"
  echo "Using NDK: $ANDROID_NDK_HOME"
}

run_tests() {
  echo "==> cargo test --workspace"
  (cd "$CORE/rust" && cargo test --workspace)
}

build_android() {
  echo "==> Android (arm64-v8a, armeabi-v7a, x86_64)"
  if ! command -v cargo-ndk >/dev/null 2>&1; then
    echo "error: cargo-ndk missing. Run: cargo install cargo-ndk"
    return 1
  fi
  if ! find_ndk; then
    echo "error: no Android NDK found. Set ANDROID_NDK_HOME."
    return 1
  fi
  bash "$CORE/scripts/build_android.sh"
}

build_ios() {
  [[ "$(uname)" == "Darwin" ]] || { echo "skip: iOS needs macOS"; return 0; }
  echo "==> iOS (device + simulator XCFramework)"
  bash "$CORE/scripts/build_ios.sh"
}

build_macos() {
  [[ "$(uname)" == "Darwin" ]] || { echo "skip: macOS needs macOS"; return 0; }
  echo "==> macOS (universal dylib)"
  bash "$CORE/scripts/build_macos.sh"
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(android)
  [[ "$(uname)" == "Darwin" ]] && targets+=(ios macos)
fi

for target in "${targets[@]}"; do
  case "$target" in
    test)    run_tests ;;
    android) build_android ;;
    ios)     build_ios ;;
    macos)   build_macos ;;
    *) echo "unknown target: $target (expected android|ios|macos|test)"; exit 1 ;;
  esac
done

echo
echo "Done. Rebuild the Flutter app so the new binaries are bundled:"
echo "  flutter clean && flutter run"
