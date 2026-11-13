#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/fixtures/Chat Preview Checks.app"
PREVIOUS="$ROOT/build/fixtures/Chat Preview Checks.previous.app"
BUNDLE_ID="com.costwisegroup.synology-chat-native.search-preview-checks"
DISPLAY_NAME="Chat Preview Checks"
SKIP_BUILD=0
WEBHOOK_RECOVERY=0
for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        --regional)
            APP="$ROOT/build/fixtures/Regional Settings Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Regional Settings Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.regional-checks"
            DISPLAY_NAME="Regional Settings Checks" ;;
        --regional-ax)
            APP="$ROOT/build/fixtures/Regional Accessibility Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Regional Accessibility Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.regional-ax-checks"
            DISPLAY_NAME="Regional Accessibility Checks" ;;
        --drops)
            APP="$ROOT/build/fixtures/Attachment Drop Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Attachment Drop Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.drop-checks"
            DISPLAY_NAME="Attachment Drop Checks" ;;
        --webhook-recovery)
            APP="$ROOT/build/fixtures/Integration Recovery Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Integration Recovery Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.webhook-recovery-checks"
            DISPLAY_NAME="Integration Recovery Checks"
            WEBHOOK_RECOVERY=1 ;;
        --timeline)
            APP="$ROOT/build/fixtures/Chat Timeline Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Chat Timeline Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.timeline-checks"
            DISPLAY_NAME="Chat Timeline Checks" ;;
        --youtube)
            APP="$ROOT/build/fixtures/Chat Video Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Chat Video Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.youtube-checks"
            DISPLAY_NAME="Chat Video Checks" ;;
        --sidebar)
            APP="$ROOT/build/fixtures/Chat Sidebar Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Chat Sidebar Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.sidebar-checks"
            DISPLAY_NAME="Chat Sidebar Checks" ;;
        --encrypted-conversations)
            APP="$ROOT/build/fixtures/Chat Encryption Checks.app"
            PREVIOUS="$ROOT/build/fixtures/Chat Encryption Checks.previous.app"
            BUNDLE_ID="com.costwisegroup.synology-chat-native.encrypted-conversation-checks"
            DISPLAY_NAME="Chat Encryption Checks" ;;
        *) echo "Usage: $0 [--skip-build] [--sidebar | --encrypted-conversations | --youtube | --timeline | --webhook-recovery | --drops | --regional | --regional-ax]" >&2; exit 2 ;;
    esac
done
if [[ "$SKIP_BUILD" != 1 ]]; then
    cd "$ROOT"
    swift build --disable-automatic-resolution
fi
[[ -f "$ROOT/.build/debug/SynologyChatNative" ]]
mkdir -p "$ROOT/build/fixtures"
STAGING="$(mktemp -d "$ROOT/build/preview-check-package.XXXXXX")"
cleanup() {
    local result=$?
    rm -rf "$STAGING"
    if [[ ! -e "$APP" && -e "$PREVIOUS" && "${MOVED:-0}" == 1 ]]; then mv "$PREVIOUS" "$APP"; fi
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$ROOT/.build/debug/SynologyChatNative" "$STAGING/Contents/MacOS/SynologyChatNative"
cp "$ROOT/packaging/NativeAppIcon.icns" "$STAGING/Contents/Resources/NativeAppIcon.icns"
cp "$ROOT/packaging/ThirdPartyNotices.txt" "$STAGING/Contents/Resources/ThirdPartyNotices.txt"
if [[ "$WEBHOOK_RECOVERY" == 1 ]]; then
    FIXTURE_DATA="$(mktemp -d /private/tmp/native-webhook-recovery-ui.XXXXXX)"
    printf '%s\n' "$FIXTURE_DATA" > "$STAGING/Contents/Resources/FixtureRecoveryDirectory.txt"
fi
python3 - "$STAGING/Contents/Info.plist" "$BUNDLE_ID" "$DISPLAY_NAME" <<'PY'
import plistlib,sys
info={'CFBundleIdentifier':sys.argv[2],'CFBundleDisplayName':sys.argv[3],'CFBundleName':sys.argv[3],'CFBundleExecutable':'SynologyChatNative','CFBundlePackageType':'APPL','CFBundleIconFile':'NativeAppIcon','CFBundleInfoDictionaryVersion':'6.0','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','LSMultipleInstancesProhibited':True,'NSHighResolutionCapable':True}
with open(sys.argv[1],'wb') as f:plistlib.dump(info,f)
PY
python3 "$ROOT/scripts/copy-native-localizations.py" --build-directory "$ROOT/.build/debug" --resources "$STAGING/Contents/Resources" --info-plist "$STAGING/Contents/Info.plist"
codesign --force --sign - "$STAGING"
codesign --verify --deep --strict "$STAGING"
if [[ -e "$APP" && -e "$PREVIOUS" ]]; then
    mkdir -p "$ROOT/build/package-history"
    HISTORY="$(mktemp -d "$ROOT/build/package-history/retained-preview-checks.XXXXXX")"
    mv "$PREVIOUS" "$HISTORY/$(basename "$APP")"
fi
if [[ -e "$APP" ]]; then mv "$APP" "$PREVIOUS";MOVED=1;fi
mv "$STAGING" "$APP"
printf '%s\n' "$APP"
