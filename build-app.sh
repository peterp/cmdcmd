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

SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$SPARKLE_FW" || { echo "missing $SPARKLE_FW — run swift package resolve"; exit 1; }

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
mkdir -p "$BUNDLE/Contents/Frameworks"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BIN" "$BUNDLE/Contents/MacOS/$BIN_NAME"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$BUNDLE/Contents/MacOS/$BIN_NAME" 2>/dev/null || true
ditto "$SPARKLE_FW" "$BUNDLE/Contents/Frameworks/Sparkle.framework"

# Sign nested Sparkle helpers (XPC services + Autoupdate.app) before sealing the framework and bundle.
SPARKLE_DIR="$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in \
    "$SPARKLE_DIR/Autoupdate.app" \
    "$SPARKLE_DIR/Updater.app" \
    "$SPARKLE_DIR/XPCServices/Installer.xpc" \
    "$SPARKLE_DIR/XPCServices/Downloader.xpc" \
    "$SPARKLE_DIR/XPCServices/org.sparkle-project.InstallerLauncher.xpc" \
    "$SPARKLE_DIR/XPCServices/org.sparkle-project.InstallerStatus.xpc" \
    "$SPARKLE_DIR/XPCServices/org.sparkle-project.Downloader.xpc"; do
    if [ -e "$item" ]; then
        codesign --force --sign - --timestamp=none --preserve-metadata=identifier,entitlements,flags --options=runtime "$item" 2>/dev/null || codesign --force --sign - "$item"
    fi
done

codesign --force --sign - "$BUNDLE/Contents/Frameworks/Sparkle.framework"

codesign --force --sign - \
    --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" \
    "$BUNDLE"

echo "Built $BUNDLE"
echo "Run: open $BUNDLE  (logs go to Console.app, filter for $BIN_NAME)"
echo "Or:  ./$BUNDLE/Contents/MacOS/$BIN_NAME"
