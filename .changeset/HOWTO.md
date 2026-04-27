# Changesets

A pending entry for the next release lives here as one markdown file per change.
Add one alongside any user-visible change, then `./release.sh` consolidates
them into a CHANGELOG entry, the appcast description, the GitHub release notes,
and the version bump.

## Format

```md
---
bump: patch
---

A short description of the change in markdown. Multiple paragraphs are fine.
```

`bump` is one of `patch`, `minor`, or `major` — the highest level across all
pending changesets wins. Bodies stack as separate paragraphs.

## Adding one

```sh
./changeset.sh "Short description"           # patch (default)
./changeset.sh minor "New feature description"
./changeset.sh major "Breaking change description"
```

The script writes `.changeset/<random-id>.md` and prints the path.

This `HOWTO.md` is ignored by the consumer because it has no frontmatter.
