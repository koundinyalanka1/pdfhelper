#!/usr/bin/env bash
#
# Build DocHelper's Rust engine libraries: the one build script for macOS,
# Linux and Git Bash on Windows (android only there). On Windows use
# scripts\build_libs.ps1, its PowerShell twin. Every engine and the PDF
# engine are built here, side by side, using every CPU core.
#
# Usage:
#   bash scripts/build_libs.sh android              # jniLibs (arm64-v8a, armeabi-v7a, x86_64)
#   bash scripts/build_libs.sh host                 # this machine, for flutter test (Linux: PDF too)
#   bash scripts/build_libs.sh macos [--host]       # dylibs (Mac); --host is this Mac's arch only
#   bash scripts/build_libs.sh ios --with-pdf       # the PDF XCFramework (only PDF has an iOS library)
#   bash scripts/build_libs.sh test [--with-pdf]    # cargo tests: doc_common and the engines
#   bash scripts/build_libs.sh fuzz [--only a,b]    # bounded verification (needs Python 3)
#   eval "$(bash scripts/build_libs.sh env)"        # *_CORE_LIB_PATH for flutter test
#   bash scripts/build_libs.sh android host         # several targets in one go
#   bash scripts/build_libs.sh android --only text,sheet
#   bash scripts/build_libs.sh android --with-pdf   # rebuild the PDF engine as well
#   bash scripts/build_libs.sh android --debug      # debug builds (the PDF engine is always release)
#   bash scripts/build_libs.sh android --jobs 4     # cores to use (default: all of them)
#
# Engines: text, sheet, word, slide, archive (pdf, and shared for fuzz, in
# --only). The PDF engine's Android and Apple binaries are committed, so it
# is rebuilt only with --with-pdf (or "pdf" in --only); the rebuilt files
# then show in packages/flutter_pdf_core's git status. On Linux, host also
# builds it, since it ships no Linux binary.
#
# Engines build side by side, each with cargo's own parallelism, and use
# every core unless --jobs (or CARGO_BUILD_JOBS) says otherwise; --jobs 1
# builds one engine at a time with one job. Several engines at once need
# more memory: use --jobs 2 on a small machine.
#
# Needs rustup (Rust 1.92+) and a linker; for android also cargo-ndk and an
# NDK (ANDROID_NDK_HOME, the Android SDK, or android/local.properties). It
# checks these first, lists everything missing with how to get it, and
# adds missing Rust targets itself.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PACKAGES="$REPO_ROOT/packages"
PDF_DIR="$PACKAGES/flutter_pdf_core"
ALL_ENGINES=(text sheet word slide archive)

PLATFORMS=()
ONLY=""
WITH_PDF=0
HOST_ONLY=0
DEBUG=0
JOBS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    android|macos|ios|host|test|env|fuzz) PLATFORMS+=("$1"); shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --jobs|-j) JOBS="${2:-}"; shift 2 ;;
    --with-pdf) WITH_PDF=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --host) HOST_ONLY=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done
[[ ${#PLATFORMS[@]} -gt 0 ]] || PLATFORMS=(android)

# Engines to build: --only picks, otherwise all five.
ENGINES=()
if [[ -n "$ONLY" ]]; then
  IFS=',' read -ra PICKED <<< "$ONLY"
  for engine in "${PICKED[@]}"; do
    case "$engine" in
      pdf) WITH_PDF=1 ;;
      shared) ;;   # only the fuzz target looks at it
      text|sheet|word|slide|archive) ENGINES+=("$engine") ;;
      *) echo "error: unknown engine '$engine' (text, sheet, word, slide, archive, pdf, shared)" >&2; exit 2 ;;
    esac
  done
else
  ENGINES=("${ALL_ENGINES[@]}")
fi

# Cores to use: --jobs, else CARGO_BUILD_JOBS, else every core.
cpu_count() {
  nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}
[[ -n "$JOBS" ]] || JOBS="${CARGO_BUILD_JOBS:-$(cpu_count)}"
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
  echo "error: --jobs needs a whole number of at least 1 (got '$JOBS')" >&2
  exit 2
fi
export CARGO_BUILD_JOBS="$JOBS"

# rustup installs here but does not always end up on a non-login shell's PATH.
if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"

OS="$(uname -s)"
case "$OS" in
  Darwin) OS_KIND=mac ;;
  Linux) OS_KIND=linux ;;
  MINGW*|MSYS*|CYGWIN*) OS_KIND=windows ;;
  *) OS_KIND=other ;;
esac
RUST_MIN_MINOR=92   # Rust 1.92 or newer

PROFILE_FLAG="--release"
PROFILE_DIR="release"
if [[ $DEBUG -eq 1 ]]; then PROFILE_FLAG=""; PROFILE_DIR="debug"; fi

# What the PDF engine adds to host: Linux builds it for flutter test unless
# --only leaves it out; a Mac only with --with-pdf (its dylib is committed).
HOST_PDF=$WITH_PDF
if [[ $OS_KIND != mac && -z "$ONLY" ]]; then HOST_PDF=1; fi

has() { command -v "$1" >/dev/null 2>&1; }
wants() { [[ " ${PLATFORMS[*]} " == *" $1 "* ]]; }

package_dir() { echo "$PACKAGES/flutter_$1_core"; }

# ---------------------------------------------------------------------------
# Prerequisites. Everything missing is collected first and reported
# together, each with how to get it, so one run tells the whole story.

PROBLEMS=()
problem() {
  local msg="  - $1" line
  shift
  for line in "$@"; do msg+=$'\n'"      $line"; done
  PROBLEMS+=("$msg")
}

ANDROID_TARGETS=(aarch64-linux-android armv7-linux-androideabi x86_64-linux-android)
MACOS_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
TARGETS_TO_ADD=()

is_ndk() { [[ -n "$1" && -d "$1/toolchains/llvm/prebuilt" ]]; }

find_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    if is_ndk "$ANDROID_NDK_HOME"; then return 0; fi
    echo "warning: ANDROID_NDK_HOME ($ANDROID_NDK_HOME) is not an NDK; looking in the Android SDK instead." >&2
  fi
  local sdks=() sdk version best=""
  [[ -n "${ANDROID_HOME:-}" ]] && sdks+=("$ANDROID_HOME")
  [[ -n "${ANDROID_SDK_ROOT:-}" ]] && sdks+=("$ANDROID_SDK_ROOT")
  if [[ -f "$REPO_ROOT/android/local.properties" ]]; then
    sdk="$(sed -n 's/^sdk\.dir=//p' "$REPO_ROOT/android/local.properties" | head -n 1 | tr -d '\r' | sed 's/\\:/:/g; s/\\\\/\\/g')"
    if [[ -n "$sdk" && $OS_KIND == windows ]] && has cygpath; then sdk="$(cygpath -u "$sdk")"; fi
    [[ -n "$sdk" ]] && sdks+=("$sdk")
  fi
  if [[ -n "${LOCALAPPDATA:-}" ]] && has cygpath; then sdks+=("$(cygpath -u "$LOCALAPPDATA")/Android/Sdk"); fi
  sdks+=("$HOME/Library/Android/sdk" "$HOME/Android/Sdk")
  for sdk in "${sdks[@]}"; do
    [[ -d "$sdk/ndk" ]] || continue
    best=""
    for version in $(ls -1 "$sdk/ndk" 2>/dev/null | sort -V); do
      is_ndk "$sdk/ndk/$version" && best="$sdk/ndk/$version"
    done
    if [[ -n "$best" ]]; then export ANDROID_NDK_HOME="$best"; return 0; fi
  done
  return 1
}

# Queues the Rust targets in "$@" that are not installed yet.
need_targets() {
  local installed target
  installed="$(rustup target list --installed 2>/dev/null || true)"
  for target in "$@"; do
    grep -qx "$target" <<< "$installed" || TARGETS_TO_ADD+=("$target")
  done
}

check_prerequisites() {
  local engine list=() env_only=0
  [[ "${PLATFORMS[*]}" == "env" ]] && env_only=1
  # Engine sources: submodules that were never checked out are empty folders.
  if [[ $env_only -eq 0 ]]; then
    list=(${ENGINES[@]+"${ENGINES[@]}"})
    if [[ $WITH_PDF -eq 1 ]] || { wants host && [[ $HOST_PDF -eq 1 ]]; }; then list+=(pdf); fi
    for engine in ${list[@]+"${list[@]}"}; do
      if [[ ! -f "$(package_dir "$engine")/rust/Cargo.toml" ]]; then
        problem "packages/flutter_${engine}_core has no Rust sources (submodule not checked out)." \
          "Run: git submodule update --init --recursive" \
          "or leave it out with --only (engines: text,sheet,word,slide,archive)"
      fi
    done
  fi
  if wants test && [[ ! -f "$PACKAGES/doc_common/Cargo.toml" ]]; then
    problem "packages/doc_common is missing." "Restore it with: git checkout -- packages/doc_common"
  fi

  # env only prints paths; it needs nothing else.
  [[ $env_only -eq 0 ]] || return 0

  # Where each target can run.
  if [[ $OS_KIND != mac ]]; then
    wants macos && problem "macos builds need a Mac." "On Linux use: bash scripts/build_libs.sh host"
    wants ios && problem "ios builds need a Mac with Xcode."
  fi
  if [[ $OS_KIND == windows ]] && wants host; then
    problem "host builds from Git Bash are not supported on Windows." \
      "Use PowerShell instead: .\\scripts\\build_libs.ps1 host"
  fi
  if wants fuzz && ! has python3 && ! has python; then
    problem "Python 3 is required for bounded verification (fuzz)." "Install it from https://www.python.org/downloads/"
  fi

  # Rust.
  if ! has cargo || ! has rustc; then
    problem "Rust (cargo, rustc) is not installed or not on PATH." \
      "Install it with rustup: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" \
      "(Windows: rustup-init.exe from https://rustup.rs), then open a new terminal."
    return
  fi
  if ! has rustup; then
    problem "rustup is not on PATH; it is needed to add Rust targets." \
      "Install Rust with rustup from https://rustup.rs (a distro Rust package has no rustup)."
    return
  fi
  local version major minor rest
  if ! version="$(rustc --version 2>/dev/null)"; then
    problem "rustc does not run (rustup has no default toolchain?)." "Run: rustup default stable"
    return
  fi
  version="$(awk '{print $2}' <<< "$version")"
  major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
     && (( major < 1 || (major == 1 && minor < RUST_MIN_MINOR) )); then
    problem "Rust $major.$minor is too old; the engines need 1.$RUST_MIN_MINOR or newer." "Run: rustup update stable"
  fi

  # A linker for this machine: build scripts and host libraries need one.
  local probe
  probe="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/dochelper_link_probe_$$")"
  mkdir -p "$probe"
  if ! echo 'fn main() {}' | rustc - -o "$probe/probe" >/dev/null 2>&1; then
    case $OS_KIND in
      mac) problem "Rust cannot link programs: the Xcode command-line tools are missing." "Run: xcode-select --install" ;;
      windows) problem "Rust cannot link Windows programs: the Visual C++ linker is missing or unusable." \
        "Use PowerShell instead: .\\scripts\\build_libs.ps1 android   (it switches to the GNU toolchain)" \
        "or install Visual Studio Build Tools with 'Desktop development with C++'." ;;
      *) problem "Rust cannot link programs: no C linker (cc) found." \
        "Debian/Ubuntu: sudo apt install build-essential" \
        "Fedora: sudo dnf install gcc    Arch: sudo pacman -S base-devel" ;;
    esac
  fi
  rm -rf "$probe"

  # Android.
  if wants android; then
    has cargo-ndk || problem "cargo-ndk is not installed." "Run: cargo install cargo-ndk"
    if find_ndk; then
      echo "Using NDK: $ANDROID_NDK_HOME" >&2
    else
      problem "No Android NDK found (looked at ANDROID_NDK_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, android/local.properties and the default SDK folders)." \
        "Android Studio: Settings > Languages & Frameworks > Android SDK > SDK Tools > NDK (Side by side)," \
        "or: sdkmanager --install \"ndk;27.2.12479018\"" \
        "or set ANDROID_NDK_HOME to an unpacked NDK."
    fi
    need_targets "${ANDROID_TARGETS[@]}"
  fi

  # Apple.
  if [[ $OS_KIND == mac ]]; then
    if wants macos || wants ios || { wants host && [[ $WITH_PDF -eq 1 || ${#ENGINES[@]} -gt 0 ]]; }; then
      if ! has lipo || ! has install_name_tool; then
        problem "lipo and install_name_tool are missing (Xcode command-line tools)." "Run: xcode-select --install"
      fi
    fi
    if wants macos && [[ $HOST_ONLY -eq 0 || $WITH_PDF -eq 1 ]]; then need_targets "${MACOS_TARGETS[@]}"; fi
    if wants host && [[ $WITH_PDF -eq 1 ]]; then need_targets "${MACOS_TARGETS[@]}"; fi
    if wants ios && [[ $WITH_PDF -eq 1 ]]; then
      has xcodebuild || problem "xcodebuild is missing; iOS builds need the full Xcode." "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
      need_targets "${IOS_TARGETS[@]}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Environment variables for flutter test.

print_env() {
  local kind upper
  for kind in ${ENGINES[@]+"${ENGINES[@]}"}; do
    upper="$(echo "$kind" | tr '[:lower:]' '[:upper:]')"
    if [[ $OS_KIND == mac ]]; then
      echo "export ${upper}_CORE_LIB_PATH=\"$(package_dir "$kind")/macos/Frameworks/lib${kind}_ffi.dylib\""
    else
      echo "export ${upper}_CORE_LIB_PATH=\"$(package_dir "$kind")/rust/target/$PROFILE_DIR/lib${kind}_ffi.so\""
    fi
  done
  if [[ $OS_KIND == mac ]]; then
    echo "export PDF_CORE_LIB_PATH=\"$PDF_DIR/macos/Frameworks/libpdf_ffi.dylib\""
  else
    echo "export PDF_CORE_LIB_PATH=\"$PDF_DIR/rust/target/release/libpdf_ffi.so\""
  fi
}

if wants env && [[ ${#PLATFORMS[@]} -eq 1 ]]; then
  print_env
  exit 0
fi

# ---------------------------------------------------------------------------
# Builds. Each takes one engine name ("pdf" is the PDF engine) and prints
# what it does; run_each runs them side by side.

# The PDF engine's committed binaries are always release builds.
set_profile() {
  KIND_FLAG="$PROFILE_FLAG"
  KIND_DIR="$PROFILE_DIR"
  if [[ "$1" == "pdf" ]]; then KIND_FLAG="--release"; KIND_DIR="release"; fi
}

build_android() {
  local kind="$1" dir extra=""
  dir="$(package_dir "$kind")"
  set_profile "$kind"
  if [[ "$kind" == "pdf" ]]; then extra="--locked"; fi
  echo "==> $kind: Android (arm64-v8a, armeabi-v7a, x86_64)"
  (cd "$dir/rust" && cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
     -o "$dir/android/src/main/jniLibs" build $extra -p "${kind}_ffi" $KIND_FLAG)
  find "$dir/android/src/main/jniLibs" -name "lib${kind}_ffi.so" -exec ls -lh {} \;
}

# mode: host (this Mac's arch only) or universal (arm64 + x86_64).
build_macos_dylib() {
  local kind="$1" mode="$2" dir lib out
  dir="$(package_dir "$kind")"
  lib="lib${kind}_ffi.dylib"
  out="$dir/macos/Frameworks"
  set_profile "$kind"
  mkdir -p "$out"
  if [[ "$mode" == "host" ]]; then
    echo "==> $kind: macOS (host only)"
    (cd "$dir/rust" && cargo build -p "${kind}_ffi" $KIND_FLAG)
    cp "$dir/rust/target/$KIND_DIR/$lib" "$out/$lib"
  else
    echo "==> $kind: macOS (universal)"
    (cd "$dir/rust" && cargo build -p "${kind}_ffi" $KIND_FLAG --target aarch64-apple-darwin \
       && cargo build -p "${kind}_ffi" $KIND_FLAG --target x86_64-apple-darwin)
    lipo -create \
      "$dir/rust/target/aarch64-apple-darwin/$KIND_DIR/$lib" \
      "$dir/rust/target/x86_64-apple-darwin/$KIND_DIR/$lib" \
      -output "$out/$lib"
  fi
  # A loader-relative install name, so app bundles can find it.
  install_name_tool -id "@rpath/$lib" "$out/$lib"
  ls -lh "$out/$lib"
}

build_macos() {
  if [[ $HOST_ONLY -eq 1 && "$1" != "pdf" ]]; then build_macos_dylib "$1" host; else build_macos_dylib "$1" universal; fi
}

build_ios() {
  local out="$PDF_DIR/ios/Frameworks" build="$PDF_DIR/rust/target" target
  local sim="$PDF_DIR/rust/target/ios-sim-universal"
  echo "==> pdf: iOS (device + simulator XCFramework)"
  (cd "$PDF_DIR/rust" && for target in "${IOS_TARGETS[@]}"; do cargo build -p pdf_ffi --release --target "$target"; done)
  mkdir -p "$sim"
  lipo -create \
    "$build/aarch64-apple-ios-sim/release/libpdf_ffi.a" \
    "$build/x86_64-apple-ios/release/libpdf_ffi.a" \
    -output "$sim/libpdf_ffi.a"
  rm -rf "$out/PdfFfi.xcframework"
  mkdir -p "$out"
  xcodebuild -create-xcframework \
    -library "$build/aarch64-apple-ios/release/libpdf_ffi.a" \
    -library "$sim/libpdf_ffi.a" \
    -output "$out/PdfFfi.xcframework"
  echo "Done: $out/PdfFfi.xcframework"
}

# For flutter test on this machine: a Mac builds its dylibs (the PDF engine's
# stays the committed universal one unless it is asked for); elsewhere each
# engine's shared object lands in its target folder.
build_host() {
  local kind="$1" dir
  dir="$(package_dir "$kind")"
  if [[ $OS_KIND == mac ]]; then
    if [[ "$kind" == "pdf" ]]; then build_macos_dylib pdf universal; else build_macos_dylib "$kind" host; fi
    return
  fi
  set_profile "$kind"
  echo "==> $kind: host ($(uname -m))"
  (cd "$dir/rust" && cargo build -p "${kind}_ffi" $KIND_FLAG)
  ls -lh "$dir/rust/target/$KIND_DIR/lib${kind}_ffi.so"
}

test_one() {
  case "$1" in
    doc_common)
      echo "==> shared crates (packages/doc_common)"
      (cd "$PACKAGES/doc_common" && cargo test --quiet) ;;
    pdf)
      echo "==> pdf"
      (cd "$PDF_DIR/rust" && cargo test --workspace --release) ;;
    *)
      echo "==> $1"
      (cd "$(package_dir "$1")/rust" && cargo test --quiet) ;;
  esac
}

# Runs "$1" once for each remaining argument, all side by side, and prints
# each one's output in order when they finish. Sequential with --jobs 1.
run_each() {
  local fn="$1" item i status=0 logdir
  local pids=() items=()
  shift
  [[ $# -gt 0 ]] || return 0
  if [[ $JOBS -le 1 || $# -le 1 ]]; then
    for item in "$@"; do "$fn" "$item" || status=1; done
    return "$status"
  fi
  echo "Building $# side by side ($JOBS cargo jobs each): $*" >&2
  logdir="$(mktemp -d)"
  for item in "$@"; do
    "$fn" "$item" >"$logdir/$item.log" 2>&1 &
    pids+=("$!")
    items+=("$item")
  done
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      status=1
      echo "error: ${items[$i]} failed; its output follows" >&2
    fi
    cat "$logdir/${items[$i]}.log"
  done
  rm -rf "$logdir"
  return "$status"
}

# ---------------------------------------------------------------------------

check_prerequisites
if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
  {
    echo
    echo "Cannot build yet; missing for '${PLATFORMS[*]}':"
    printf '%s\n' "${PROBLEMS[@]}"
    echo
    echo "Fix these, open a new terminal if you installed something, and run the script again."
  } >&2
  exit 1
fi
if [[ ${#TARGETS_TO_ADD[@]} -gt 0 ]]; then
  echo "Adding Rust targets: ${TARGETS_TO_ADD[*]}" >&2
  if ! rustup target add "${TARGETS_TO_ADD[@]}" >&2; then
    echo "error: could not add the Rust targets (offline?). Run: rustup target add ${TARGETS_TO_ADD[*]}" >&2
    exit 1
  fi
fi

# What to build: the engines, then the PDF engine when asked for.
TASKS=(${ENGINES[@]+"${ENGINES[@]}"})
if [[ $WITH_PDF -eq 1 ]]; then TASKS+=(pdf); fi
HOST_TASKS=(${ENGINES[@]+"${ENGINES[@]}"})
if [[ $HOST_PDF -eq 1 ]]; then HOST_TASKS+=(pdf); fi

FAILED=0
for platform in "${PLATFORMS[@]}"; do
  echo "######## $platform" >&2
  case "$platform" in
    android) run_each build_android ${TASKS[@]+"${TASKS[@]}"} || FAILED=1 ;;
    macos) run_each build_macos ${TASKS[@]+"${TASKS[@]}"} || FAILED=1 ;;
    ios)
      if [[ $WITH_PDF -eq 1 ]]; then
        build_ios || FAILED=1
      else
        echo "Only the PDF engine has an iOS library; add --with-pdf to rebuild it."
      fi
      ;;
    host) run_each build_host ${HOST_TASKS[@]+"${HOST_TASKS[@]}"} || FAILED=1 ;;
    test) run_each test_one doc_common ${TASKS[@]+"${TASKS[@]}"} || FAILED=1 ;;
    fuzz)
      if has python3; then PYTHON=python3; else PYTHON=python; fi
      "$PYTHON" "$HERE/verify_engines.py" fuzz --only "${ONLY:-shared,pdf,text,sheet,word,slide,archive}" || FAILED=1
      ;;
    env) print_env ;;
  esac
done

if [[ $FAILED -ne 0 ]]; then
  echo "Failed: see the output above." >&2
  exit 1
fi
echo "Done." >&2
if wants android; then
  if has flutter; then
    echo "Next: flutter pub get, then flutter run -d <device-id> (flutter devices lists them)." >&2
  else
    echo "Next: flutter run. Flutter is not on PATH: install it from https://docs.flutter.dev/get-started/install or add <flutter>/bin to PATH." >&2
  fi
fi
