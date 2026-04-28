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

## Enforcement

The `changeset` GitHub Action fails any PR that doesn't add a file under
`.changeset/`. Apply the `skip-changeset` label to opt out (e.g. CI-only or
docs-only changes).

Bodies appear verbatim in the Sparkle update dialog — write them user-facing
and avoid markdown (backticks, links, headings). Newlines render as `<br>`.
