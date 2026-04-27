#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <short-version>   e.g. 0.1.3"
    exit 1
fi

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

./build-app.sh release
ditto -c -k --keepParent cmdcmd.app cmdcmd.zip

SPARKLE_KEY_REF="${SPARKLE_KEY_REF:-op://Private/cmdcmd Sparkle key/password}"
SIGN_OUT=$(op read "$SPARKLE_KEY_REF" | .build/artifacts/sparkle/Sparkle/bin/sign_update -f - cmdcmd.zip)
SIZE=$(stat -f%z cmdcmd.zip)
ED_SIG=$(printf '%s' "$SIGN_OUT" | sed -E 's/.*edSignature="([^"]+)".*/\1/')

cat > appcast.xml <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmdcmd</title>
        <link>https://raw.githubusercontent.com/peterp/cmdcmd/main/appcast.xml</link>
        <description>cmdcmd updates</description>
        <language>en</language>
        <item>
            <title>v$VERSION</title>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>$PUBDATE</pubDate>
            <enclosure url="https://github.com/peterp/cmdcmd/releases/download/v$VERSION/cmdcmd.zip"
                       sparkle:edSignature="$ED_SIG"
                       length="$SIZE"
                       type="application/octet-stream" />
        </item>
    </channel>
</rss>
EOF

echo
echo "Built cmdcmd.zip ($SIZE bytes) and appcast.xml for v$VERSION (build $BUILD)."
echo "Next: commit appcast.xml, tag v$VERSION, push, then 'gh release create v$VERSION cmdcmd.zip'."
