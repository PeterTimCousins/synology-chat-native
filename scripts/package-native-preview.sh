#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Synology Chat API Preview.app"
cd "$ROOT"
swift build --disable-automatic-resolution
mkdir -p "$ROOT/build"
STAGING="$(mktemp -d "$ROOT/build/native-preview-package.XXXXXX")"
PREVIOUS=""
MOVED_PREVIOUS=0
cleanup() {
    local result=$?
    rm -rf "$STAGING"
    if [[ ! -e "$APP_DIR" && "${MOVED_PREVIOUS:-0}" == 1 && -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$APP_DIR"; fi
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$ROOT/.build/debug/SynologyChatNative" "$STAGING/Contents/MacOS/SynologyChatNative"
cp "$ROOT/packaging/Info.plist" "$STAGING/Contents/Info.plist"
cp "$ROOT/packaging/PreviewAppIcon.icns" "$STAGING/Contents/Resources/PreviewAppIcon.icns"
cp "$ROOT/packaging/ThirdPartyNotices.txt" "$STAGING/Contents/Resources/ThirdPartyNotices.txt"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.costwisegroup.synology-chat-native.api-preview' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Chat Native Preview' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Chat Native Preview' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile PreviewAppIcon' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSCameraUsageDescription' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSMicrophoneUsageDescription' "$STAGING/Contents/Info.plist"
python3 "$ROOT/scripts/copy-native-localizations.py" --build-directory "$ROOT/.build/debug" --resources "$STAGING/Contents/Resources" --info-plist "$STAGING/Contents/Info.plist"
codesign --force --sign - "$STAGING"
codesign --verify --deep --strict "$STAGING"
if [[ -e "$APP_DIR" ]]; then
    mkdir -p "$ROOT/build/package-history"
    HISTORY="$(mktemp -d "$ROOT/build/package-history/retained-native-preview.XXXXXX")"
    PREVIOUS="$HISTORY/$(basename "$APP_DIR")"
    mv "$APP_DIR" "$PREVIOUS"
    MOVED_PREVIOUS=1
fi
mv "$STAGING" "$APP_DIR"
printf '%s\n' "$APP_DIR"
