#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Collect changesets — files with a YAML frontmatter starting with `---`.
shopt -s nullglob
PENDING=()
for file in .changeset/*.md; do
    [ "$(head -n1 "$file")" = "---" ] || continue
    PENDING+=("$file")
done

if [ ${#PENDING[@]} -eq 0 ]; then
    echo "no pending changesets in .changeset/ — run ./changeset.sh first"
    exit 1
fi

# Determine highest bump level across pending changesets.
BUMP=patch
for file in "${PENDING[@]}"; do
    level=$(awk -F': *' '$1 == "bump" { print $2; exit }' "$file")
    case "$level" in
        major) BUMP=major; break ;;
        minor) [ "$BUMP" = patch ] && BUMP=minor ;;
        patch) ;;
        *) echo "$file: unknown bump '$level'"; exit 1 ;;
    esac
done

# Compute next version + build number.
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
IFS='.' read -r MAJ MIN PAT <<< "$CURRENT"
case "$BUMP" in
    major) MAJ=$((MAJ+1)); MIN=0; PAT=0 ;;
    minor) MIN=$((MIN+1)); PAT=0 ;;
    patch) PAT=$((PAT+1)) ;;
esac
NEXT="$MAJ.$MIN.$PAT"
BUILD=$(($(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)+1))

echo "==> $CURRENT -> $NEXT ($BUMP) build $BUILD"

# Concatenate bodies (text after the second `---`) into release notes.
extract_body() {
    awk 'BEGIN{c=0} /^---$/{c++; next} c>=2' "$1"
}
NOTES=""
APPCAST_PARAGRAPHS=""
for file in "${PENDING[@]}"; do
    body=$(extract_body "$file" | sed -e '/./,$!d' | awk '{lines=lines $0 "\n"} END{sub(/\n+$/, "", lines); print lines}')
    [ -n "$body" ] || continue
    NOTES+="$body"$'\n\n'
    APPCAST_PARAGRAPHS+="<p>${body//$'\n'/<br>}</p>"
done
NOTES=${NOTES%$'\n\n'}

# Bump Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

# Prepend to CHANGELOG.md.
DATE=$(date "+%Y-%m-%d")
TMP=$(mktemp)
{
    echo "## v$NEXT — $DATE"
    echo
    echo "$NOTES"
    echo
    if [ -f CHANGELOG.md ]; then
        cat CHANGELOG.md
    fi
} > "$TMP"
mv "$TMP" CHANGELOG.md

# Build + zip.
./build-app.sh release
ditto -c -k --keepParent cmdcmd.app cmdcmd.zip

# Sign with Sparkle key from 1Password.
SPARKLE_KEY_REF="${SPARKLE_KEY_REF:-op://Private/cmdcmd Sparkle key/password}"
SIGN_OUT=$(op read "$SPARKLE_KEY_REF" | .build/artifacts/sparkle/Sparkle/bin/sign_update -f - cmdcmd.zip)
SIZE=$(stat -f%z cmdcmd.zip)
ED_SIG=$(printf '%s' "$SIGN_OUT" | sed -E 's/.*edSignature="([^"]+)".*/\1/')
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# Generate appcast.xml.
cat > appcast.xml <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmdcmd</title>
        <link>https://raw.githubusercontent.com/peterp/cmdcmd/main/appcast.xml</link>
        <description>cmdcmd updates</description>
        <language>en</language>
        <item>
            <title>v$NEXT</title>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$NEXT</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[${APPCAST_PARAGRAPHS}]]></description>
            <pubDate>$PUBDATE</pubDate>
            <enclosure url="https://github.com/peterp/cmdcmd/releases/download/v$NEXT/cmdcmd.zip"
                       sparkle:edSignature="$ED_SIG"
                       length="$SIZE"
                       type="application/octet-stream" />
        </item>
    </channel>
</rss>
EOF

# Consume changesets.
git rm -f "${PENDING[@]}" >/dev/null

# Commit + tag + push.
git add Resources/Info.plist appcast.xml CHANGELOG.md
git commit -m "Release v$NEXT"
git tag -a "v$NEXT" -m "v$NEXT"
git push origin main
git push origin "v$NEXT"

# GitHub release.
RELEASE_BODY="## What's new

$NOTES

## Install

1. Download \`cmdcmd.zip\` and unzip.
2. Drag \`cmdcmd.app\` to \`/Applications\`.
3. Strip quarantine: \`xattr -dr com.apple.quarantine /Applications/cmdcmd.app\` (or System Settings → Privacy & Security → Open Anyway after the first failed launch).
4. Grant Screen Recording + Accessibility on first launch.

Existing v0.1.3+ users will be offered this update automatically via Sparkle.

Requires macOS 14+. Apple-silicon build."
gh release create "v$NEXT" cmdcmd.zip --title "v$NEXT" --notes "$RELEASE_BODY"

echo "Released v$NEXT."
