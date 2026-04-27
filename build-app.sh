#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
BIN_NAME="cmdcmd"
BUNDLE="cmdcmd.app"
BUNDLE_ID="com.p4p8.cmdcmd"

swift build -c "$CONFIG"

BIN=".build/$CONFIG/$BIN_NAME"
test -f "$BIN" || { echo "missing $BIN"; exit 1; }
test -f Resources/AppIcon.icns || { echo "missing Resources/AppIcon.icns — run ./make-icon.sh"; exit 1; }

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BIN" "$BUNDLE/Contents/MacOS/$BIN_NAME"

codesign --force --sign - \
    --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" \
    "$BUNDLE"

echo "Built $BUNDLE"
echo "Run: open $BUNDLE  (logs go to Console.app, filter for $BIN_NAME)"
echo "Or:  ./$BUNDLE/Contents/MacOS/$BIN_NAME"
