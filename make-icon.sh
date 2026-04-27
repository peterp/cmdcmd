#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release
BIN=.build/release/cmdcmd
test -f "$BIN" || { echo "missing $BIN"; exit 1; }

ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$ICONSET/icon_512x512.png" Resources/AppIcon.png

echo "Wrote Resources/AppIcon.icns and Resources/AppIcon.png"
