#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "usage: $0 [patch|minor|major] \"summary\""
    echo "   or: $0 \"summary\"            # patch (default)"
    exit 1
}

case "${1:-}" in
    patch|minor|major)
        BUMP="$1"
        SUMMARY="${2:-}"
        ;;
    "" )
        usage
        ;;
    * )
        BUMP="patch"
        SUMMARY="$1"
        ;;
esac

mkdir -p .changeset
ID=$(openssl rand -hex 4)
FILE=".changeset/$ID.md"

{
    echo "---"
    echo "bump: $BUMP"
    echo "---"
    echo
    if [ -n "$SUMMARY" ]; then
        echo "$SUMMARY"
    else
        echo "Describe the change here."
    fi
} > "$FILE"

echo "Wrote $FILE (bump: $BUMP)"
if [ -z "$SUMMARY" ]; then
    echo "Open it and replace the placeholder with the real summary."
fi
