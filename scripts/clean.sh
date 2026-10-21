#!/usr/bin/env bash
#
# Remove everything DocHelper can generate or download again (macOS, Linux,
# Git Bash on Windows; scripts/clean.ps1 is the PowerShell twin):
#
#   - flutter clean in the app and in every Flutter package;
#   - build/, .dart_tool/, coverage, Flutter's ephemeral folders, CocoaPods
#     (Pods/, .symlinks/), the Gradle wrapper, .gradle/ and .kotlin/;
#   - every Rust target/ folder (doc_common and each engine);
#   - the per-format engines' built binaries (jniLibs, dylibs, frameworks);
#   - the packages' pubspec.lock files (git-ignored; pub get remakes them);
#   - the downloaded test corpus (test_corpus/, test_pvs_output/).
#
# Nothing git tracks is ever removed: the PDF engine's committed binaries,
# the app's pubspec.lock and Podfile.lock stay. android/local.properties
# (your SDK path) is kept too.
#
# Usage:
#   bash scripts/clean.sh                # remove it all
#   bash scripts/clean.sh --dry-run      # only list what would go
#   bash scripts/clean.sh --keep-corpus  # keep test_corpus/
#   bash scripts/clean.sh --no-flutter   # skip flutter clean
#
# Afterwards: flutter pub get, then bash scripts/build_libs.sh android (or
# host) to build the engines again.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY=0
KEEP_CORPUS=0
RUN_FLUTTER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --keep-corpus) KEEP_CORPUS=1 ;;
    --no-flutter) RUN_FLUTTER=0 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v git >/dev/null 2>&1; then
  {
    echo "Missing: git. It is needed to make sure no tracked file is removed."
    echo "  macOS: xcode-select --install   Debian/Ubuntu: sudo apt install git   Fedora: sudo dnf install git"
    echo "  Others: https://git-scm.com/downloads"
  } >&2
  exit 1
fi
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  {
    echo "$REPO_ROOT is not a git checkout, so tracked files cannot be told apart; nothing removed."
    echo "  Clone the repository with: git clone --recurse-submodules <repository-url>"
  } >&2
  exit 1
fi

shopt -s nullglob

REMOVED=0
FAILED=0

# Whether git tracks the path, or anything inside it, in whichever
# repository (the app or an engine submodule) holds it.
is_tracked() {
  local dir base
  dir="$(dirname "$1")"
  base="$(basename "$1")"
  [[ -n "$(git -C "$dir" ls-files -- "$base" 2>/dev/null | head -n 1)" ]]
}

remove() {
  local path rel
  for path in "$@"; do
    path="${path%/}"
    [[ -e "$path" || -L "$path" ]] || continue
    rel="${path#"$REPO_ROOT"/}"
    if is_tracked "$path"; then
      echo "  keep     $rel (tracked by git)"
      continue
    fi
    if [[ $DRY -eq 1 ]]; then
      echo "  would remove $rel"
      REMOVED=$((REMOVED + 1))
    elif rm -rf -- "$path"; then
      echo "  removed  $rel"
      REMOVED=$((REMOVED + 1))
    else
      echo "  FAILED   $rel" >&2
      FAILED=$((FAILED + 1))
    fi
  done
}

find_flutter() {
  if command -v flutter >/dev/null 2>&1; then command -v flutter; return; fi
  if [[ -n "${FLUTTER_ROOT:-}" && -x "$FLUTTER_ROOT/bin/flutter" ]]; then
    echo "$FLUTTER_ROOT/bin/flutter"; return
  fi
  for candidate in "$HOME/flutter/bin/flutter" "$HOME/development/flutter/bin/flutter" /opt/flutter/bin/flutter; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return; }
  done
}

# Flutter projects: the app, every Flutter package and their examples.
FLUTTER_DIRS=("$REPO_ROOT")
for pubspec in "$REPO_ROOT"/packages/*/pubspec.yaml "$REPO_ROOT"/packages/*/example/pubspec.yaml; do
  FLUTTER_DIRS+=("$(dirname "$pubspec")")
done

# A running Gradle daemon keeps files in android/.gradle open.
if [[ $DRY -eq 0 && -x "$REPO_ROOT/android/gradlew" ]]; then
  echo "==> stopping Gradle daemons"
  (cd "$REPO_ROOT/android" && ./gradlew --stop >/dev/null 2>&1) || true
fi

if [[ $RUN_FLUTTER -eq 1 ]]; then
  FLUTTER="$(find_flutter)"
  if [[ -z "$FLUTTER" ]]; then
    echo "==> flutter not found; skipping flutter clean (the folders below are removed anyway)."
    echo "    Install it from https://docs.flutter.dev/get-started/install, or set FLUTTER_ROOT or add <flutter>/bin to PATH."
  else
    echo "==> flutter clean"
    for dir in "${FLUTTER_DIRS[@]}"; do
      rel="${dir#"$REPO_ROOT"}"; rel="${rel#/}"; rel="${rel:-.}"
      if [[ $DRY -eq 1 ]]; then
        echo "  would run flutter clean in $rel"
      elif (cd "$dir" && "$FLUTTER" clean >/dev/null 2>&1); then
        echo "  cleaned  $rel"
      else
        echo "  flutter clean failed in $rel (the folders below are removed anyway)"
      fi
    done
  fi
fi

R="$REPO_ROOT"
echo "==> app"
remove \
  "$R/build" "$R/.dart_tool" "$R/coverage" "$R/.flutter-plugins" "$R/.flutter-plugins-dependencies" \
  "$R/android/.gradle" "$R/android/.kotlin" "$R/android/build" "$R/android/app/build" "$R/android/app/.cxx" \
  "$R/android/gradlew" "$R/android/gradlew.bat" "$R/android/gradle/wrapper/gradle-wrapper.jar" \
  "$R/ios/Pods" "$R/ios/.symlinks" "$R/ios/build" "$R/ios/Flutter/ephemeral" \
  "$R/ios/Flutter/Generated.xcconfig" "$R/ios/Flutter/flutter_export_environment.sh" "$R/ios/Flutter/Flutter.podspec" \
  "$R/macos/Pods" "$R/macos/build" "$R/macos/Flutter/ephemeral" \
  "$R/linux/flutter/ephemeral" "$R/windows/flutter/ephemeral"

echo "==> downloaded test files"
remove "$R/test_pvs_output"
if [[ $KEEP_CORPUS -eq 0 ]]; then remove "$R/test_corpus"; else echo "  keep     test_corpus (--keep-corpus)"; fi

echo "==> packages"
for pkg in "$R"/packages/*/; do
  pkg="${pkg%/}"
  remove \
    "$pkg/target" "$pkg/rust/target" "$pkg/tools/pdf_viewer/target" \
    "$pkg/build" "$pkg/.dart_tool" "$pkg/.flutter-plugins" "$pkg/.flutter-plugins-dependencies" "$pkg/pubspec.lock" \
    "$pkg/example/build" "$pkg/example/.dart_tool" "$pkg/example/pubspec.lock" \
    "$pkg/ios/Frameworks"
  remove "$pkg"/android/src/main/jniLibs/*/ "$pkg"/macos/Frameworks/*.dylib
done

echo
if [[ $DRY -eq 1 ]]; then
  echo "Dry run: $REMOVED item(s) would be removed."
else
  echo "Done: $REMOVED item(s) removed, $FAILED failed."
  echo "Next: flutter pub get, then bash scripts/build_libs.sh android (or host)."
fi
[[ $FAILED -eq 0 ]]
