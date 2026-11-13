#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Synology Chat Native API.app"
PREVIOUS="$ROOT/build/Synology Chat Native API.previous.app"
case "${1:-}" in
    "") ;;
    --candidate)
        APP_DIR="$ROOT/build/candidates/Synology Chat Native API.app"
        PREVIOUS="$ROOT/build/candidates/Synology Chat Native API.previous.app"
        ;;
    *) echo "Usage: $0 [--candidate]" >&2; exit 2 ;;
esac
cd "$ROOT"
swift build -c release
mkdir -p "$ROOT/build"
mkdir -p "$(dirname "$APP_DIR")"
STAGING="$(mktemp -d "$ROOT/build/native-api-package.XXXXXX")"
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
cp "$ROOT/packaging/NativeAppIcon.icns" "$STAGING/Contents/Resources/NativeAppIcon.icns"
cp "$ROOT/packaging/ThirdPartyNotices.txt" "$STAGING/Contents/Resources/ThirdPartyNotices.txt"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.costwisegroup.synology-chat-native.api' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Chat Native' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Chat Native' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile NativeAppIcon' "$STAGING/Contents/Info.plist"
# The wrapper's web transport/media declarations do not apply to the API client.
/usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSCameraUsageDescription' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSMicrophoneUsageDescription' "$STAGING/Contents/Info.plist"
python3 "$ROOT/scripts/copy-native-localizations.py" --build-directory "$ROOT/.build/release" --resources "$STAGING/Contents/Resources" --info-plist "$STAGING/Contents/Info.plist"
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
