## v0.2.1 — 2026-05-01

Refresh tile aspect ratio when a window is resized between overlay opens. Previously, resizing a window while the overlay was hidden would leave the next cmd-cmd showing the tile at its old aspect ratio (and capturing the live preview at the old dimensions) until something else added or removed a window.

## v0.2.0 — 2026-05-01

Smoother peek (hold Space): the blue selection halo no longer flashes ahead of the tile when zooming, and fades cleanly while the preview is held.

Refresh tile previews on every overlay show so live updates aren't masked by the previous capture

Search mode (cmd+F): filter tiles by substring match on app name + window title. Use the arrow keys to move the tile selection from inside the search field; return commits, esc / Cancel clears.

Fix a crash when ScreenCaptureKit returns no image for a window (some DRM-protected content like Netflix in Firefox). The capture is now skipped quietly instead of taking the app down.

Live previews now recover automatically when ScreenCaptureKit drops a window's stream (minimised app, system suspension, capture daemon restarts). The tile keeps showing the last frame and the live capture resumes within a couple of seconds.

## v0.1.7 — 2026-04-29

Refresh the window grid on every overlay open: cached tiles still render instantly, but a fresh window list is fetched in parallel and reconciled in — newly opened windows fade in, closed ones fade out, and the rest animate to their new grid positions.

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

