## v0.1.6 — 2026-04-28

More reliable cmd-cmd chord detection via a session event tap.

Type an app's first letter to select it in the overlay; repeat to cycle matches.

Add reusable NSWindow fade-in/out animation helpers.

Add a display-mode setting: dock, menu bar, or hidden.

Internal: CI now requires a changeset on every PR (label skip-changeset to opt out).

Optionally order tiles by recent app usage.

Use the bundled app icon for the Dock instead of overriding at runtime.

Add a built-in Settings window for visual config (animations and live previews) with live apply.

## v0.1.5 — 2026-04-28

Add a changeset-driven release flow: drop a markdown entry in `.changeset/` per change; `./release.sh` consolidates pending entries into a CHANGELOG.md section, the appcast description, and the GitHub release notes, then bumps the version automatically.

