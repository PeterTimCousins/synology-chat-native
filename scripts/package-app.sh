#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Synology Chat Native"
APP_DIR="$ROOT/build/$APP_NAME.app"
EXECUTABLE="$ROOT/.build/release/SynologyChatNative"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/SynologyChatNative"
cp "$ROOT/packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
