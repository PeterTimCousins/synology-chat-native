#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Synology Chat Native.app"
PREVIOUS="$ROOT/build/Synology Chat Native.previous.app"
cd "$ROOT"
swift build -c release
mkdir -p "$ROOT/build"
STAGING="$(mktemp -d "$ROOT/build/native-wrapper-package.XXXXXX")"
cleanup() {
    local result=$?
    rm -rf "$STAGING"
    if [[ ! -e "$APP_DIR" && -e "$PREVIOUS" && "${MOVED_PREVIOUS:-0}" == 1 ]]; then
        mv "$PREVIOUS" "$APP_DIR"
    fi
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$ROOT/.build/release/SynologyChatNative" "$STAGING/Contents/MacOS/SynologyChatNative"
cp "$ROOT/packaging/Info.plist" "$STAGING/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"
cp "$ROOT/packaging/ThirdPartyNotices.txt" "$STAGING/Contents/Resources/ThirdPartyNotices.txt"
codesign --force --sign - "$STAGING"
codesign --verify --strict "$STAGING"
# Retain older builds only after the replacement is fully built and verified.
if [[ -e "$APP_DIR" && -e "$PREVIOUS" ]]; then
    mkdir -p "$ROOT/build/package-history"
    HISTORY_DIR="$(mktemp -d "$ROOT/build/package-history/retained-build.XXXXXX")"
    mv "$PREVIOUS" "$HISTORY_DIR/$(basename "$APP_DIR")"
fi
if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$PREVIOUS"
    MOVED_PREVIOUS=1
fi
mv "$STAGING" "$APP_DIR"
printf '%s\n' "$APP_DIR"
