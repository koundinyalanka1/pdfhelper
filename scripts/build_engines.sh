#!/usr/bin/env bash
#
# Build DocHelper's per-format engine libraries: one Rust library for each
# kind of file (see PLAN.md). The PDF engine keeps its own script,
# scripts/build_pdf_core.sh.
#
#   text   -> packages/flutter_text_core   (libtext_ffi)
#   sheet  -> packages/flutter_sheet_core  (libsheet_ffi)
#   word   -> packages/flutter_word_core   (libword_ffi)
#   slide  -> packages/flutter_slide_core  (libslide_ffi)
#
# Engines whose package does not exist yet are skipped.
#
# Usage:
#   bash scripts/build_engines.sh android             # jniLibs, every engine
#   bash scripts/build_engines.sh macos               # universal dylibs
#   bash scripts/build_engines.sh macos --host        # this Mac's arch only (faster)
#   bash scripts/build_engines.sh host                # this machine (Linux or Mac) for
#                                                     # flutter test; on Linux also the
#                                                     # PDF engine, which ships no Linux binary
#   bash scripts/build_engines.sh test                # cargo test, shared crates + engines
#   bash scripts/build_engines.sh android --only text,sheet
#   eval "$(bash scripts/build_engines.sh env)"       # *_CORE_LIB_PATH for flutter test
#
# Prerequisites are those of build_pdf_core.sh: rustup, the Android targets,
# cargo-ndk and an NDK for android; the Apple targets for macos.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALL_ENGINES=(text sheet word slide)

if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"

package_dir() { echo "$REPO_ROOT/packages/flutter_$1_core"; }

PLATFORMS=()
ONLY=""
HOST_ONLY=0
DEBUG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --host) HOST_ONLY=1; shift ;;
    --debug) DEBUG=1; shift ;;
    android|macos|host|test|env) PLATFORMS+=("$1"); shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1'"; exit 1 ;;
  esac
done
[[ ${#PLATFORMS[@]} -gt 0 ]] || PLATFORMS=(android)

ENGINES=()
for engine in "${ALL_ENGINES[@]}"; do
  if [[ -n "$ONLY" && ",$ONLY," != *",$engine,"* ]]; then continue; fi
  if [[ -f "$(package_dir "$engine")/rust/Cargo.toml" ]]; then ENGINES+=("$engine"); fi
done

if [[ " ${PLATFORMS[*]} " == *" env "* ]]; then
  # macOS: the dylibs that `macos` or `host` put in each package. Linux: the
  # shared objects `host` leaves in each Rust workspace's target directory.
  for engine in "${ENGINES[@]}"; do
    upper="$(echo "$engine" | tr '[:lower:]' '[:upper:]')"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "export ${upper}_CORE_LIB_PATH=\"$(package_dir "$engine")/macos/Frameworks/lib${engine}_ffi.dylib\""
    else
      echo "export ${upper}_CORE_LIB_PATH=\"$(package_dir "$engine")/rust/target/release/lib${engine}_ffi.so\""
    fi
  done
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "export PDF_CORE_LIB_PATH=\"$REPO_ROOT/packages/flutter_pdf_core/macos/Frameworks/libpdf_ffi.dylib\""
  else
    echo "export PDF_CORE_LIB_PATH=\"$REPO_ROOT/packages/flutter_pdf_core/rust/target/release/libpdf_ffi.so\""
  fi
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust from https://rustup.rs and retry."
  exit 1
fi

PROFILE_FLAG="--release"
PROFILE_DIR="release"
if [[ $DEBUG -eq 1 ]]; then PROFILE_FLAG=""; PROFILE_DIR="debug"; fi

find_ndk() {
  [[ -n "${ANDROID_NDK_HOME:-}" ]] && return 0
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  [[ -d "$sdk/ndk" ]] || return 1
  local latest
  latest="$(ls -1 "$sdk/ndk" | sort -V | tail -1)"
  [[ -n "$latest" ]] || return 1
  export ANDROID_NDK_HOME="$sdk/ndk/$latest"
}

build_android() {
  local engine="$1" dir
  dir="$(package_dir "$engine")"
  echo "==> $engine: Android (arm64-v8a, armeabi-v7a, x86_64)"
  (cd "$dir/rust" && cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
     -o "$dir/android/src/main/jniLibs" build -p "${engine}_ffi" $PROFILE_FLAG)
  find "$dir/android/src/main/jniLibs" -name '*.so' -exec ls -lh {} \;
}

build_macos() {
  local engine="$1" dir lib out
  dir="$(package_dir "$engine")"
  lib="lib${engine}_ffi.dylib"
  out="$dir/macos/Frameworks"
  mkdir -p "$out"
  if [[ $HOST_ONLY -eq 1 ]]; then
    echo "==> $engine: macOS (host only)"
    (cd "$dir/rust" && cargo build -p "${engine}_ffi" $PROFILE_FLAG)
    cp "$dir/rust/target/$PROFILE_DIR/$lib" "$out/$lib"
  else
    echo "==> $engine: macOS (universal)"
    (cd "$dir/rust" && cargo build -p "${engine}_ffi" $PROFILE_FLAG --target aarch64-apple-darwin \
       && cargo build -p "${engine}_ffi" $PROFILE_FLAG --target x86_64-apple-darwin)
    lipo -create \
      "$dir/rust/target/aarch64-apple-darwin/$PROFILE_DIR/$lib" \
      "$dir/rust/target/x86_64-apple-darwin/$PROFILE_DIR/$lib" \
      -output "$out/$lib"
  fi
  install_name_tool -id "@rpath/$lib" "$out/$lib"
  ls -lh "$out/$lib"
}

build_host() {
  local engine="$1" dir
  dir="$(package_dir "$engine")"
  if [[ "$(uname)" == "Darwin" ]]; then
    HOST_ONLY=1 build_macos "$engine"
    return
  fi
  echo "==> $engine: host ($(uname -m))"
  (cd "$dir/rust" && cargo build -p "${engine}_ffi" $PROFILE_FLAG)
  ls -lh "$dir/rust/target/$PROFILE_DIR/lib${engine}_ffi.so"
}

build_pdf_host() {
  # The PDF engine commits Android and Apple binaries only.
  [[ "$(uname)" == "Darwin" ]] && return
  echo "==> pdf: host ($(uname -m))"
  (cd "$REPO_ROOT/packages/flutter_pdf_core/rust" && cargo build -p pdf_ffi $PROFILE_FLAG)
  ls -lh "$REPO_ROOT/packages/flutter_pdf_core/rust/target/$PROFILE_DIR/libpdf_ffi.so"
}

run_tests() {
  echo "==> shared crates (packages/doc_common)"
  (cd "$REPO_ROOT/packages/doc_common" && cargo test --quiet)
  for engine in "${ENGINES[@]}"; do
    echo "==> $engine"
    (cd "$(package_dir "$engine")/rust" && cargo test --quiet)
  done
}

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    android)
      if ! command -v cargo-ndk >/dev/null 2>&1; then
        echo "error: cargo-ndk missing. Run: cargo install cargo-ndk"; exit 1
      fi
      find_ndk || { echo "error: no Android NDK found. Set ANDROID_NDK_HOME."; exit 1; }
      for engine in "${ENGINES[@]}"; do build_android "$engine"; done
      ;;
    macos)
      [[ "$(uname)" == "Darwin" ]] || { echo "error: macos builds need a Mac"; exit 1; }
      for engine in "${ENGINES[@]}"; do build_macos "$engine"; done
      ;;
    host)
      for engine in "${ENGINES[@]}"; do build_host "$engine"; done
      build_pdf_host
      ;;
    test) run_tests ;;
  esac
done
