#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build
mkdir -p "$ROOT/build/fixtures"
APP="$ROOT/build/fixtures/Channel Settings Test.app"
STAGING="$(mktemp -d "$ROOT/build/fixtures/channel-settings-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$ROOT/.build/debug/SynologyChatNative" "$STAGING/Contents/MacOS/SynologyChatNative"
cp "$ROOT/packaging/Info.plist" "$STAGING/Contents/Info.plist"
cp "$ROOT/packaging/PreviewAppIcon.icns" "$STAGING/Contents/Resources/PreviewAppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.costwisegroup.synology-chat-native.channel-settings-fixture' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Channel Settings Test' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Channel Settings Test' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile PreviewAppIcon' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSAppTransportSecurity' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSCameraUsageDescription' "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSMicrophoneUsageDescription' "$STAGING/Contents/Info.plist"
python3 "$ROOT/scripts/copy-native-localizations.py" --build-directory "$ROOT/.build/debug" --resources "$STAGING/Contents/Resources" --info-plist "$STAGING/Contents/Info.plist"
codesign --force --sign - "$STAGING"
codesign --verify --deep --strict "$STAGING"
if [[ -e "$APP" ]]; then
    HISTORY="$(mktemp -d "$ROOT/build/fixtures/retained-channel-settings.XXXXXX")"
    mv "$APP" "$HISTORY/Channel Settings Test.app"
fi
mv "$STAGING" "$APP"
printf '%s\n' "$APP"
