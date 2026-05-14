## v0.4.0 — 2026-05-14

Replace per-window `SCStream` with polled `CGSHWCaptureWindowList` (private SkyLight) for live tile previews. Window enumeration also moves off ScreenCaptureKit to `CGWindowListCopyWindowInfo`, eliminating the SCK setup race fixed in #18 and dropping the CPU/GPU cost of N concurrent streams. Screen Recording permission is still required — current macOS gates `CGSHWCaptureWindowList` on it and still attributes capture to the app via the menu-bar indicator. See issue #21.

## v0.3.2 — 2026-05-14

Fix a crash on the overlay's first open on macOS 26 when several windows are visible. The capture-setup calls used by each tile are now serialized so the framework no longer sees overlapping inits.

## v0.3.1 — 2026-05-06

Fix WhatsApp tile label showing as just "a" — strip Unicode formatting characters (e.g. U+200E LRM in WhatsApp's display name) before deriving the letter-pick prefix.

## v0.3.0 — 2026-05-06

Add letter-prefix tile labels (default). Each tile gets a 2-char prefix from its app name (e.g. "gc" Google Chrome, "wa" WhatsApp); type the prefix to pick. Settings → Tile labels → Numbers to keep the previous 1-9 / wasd behavior.

Drop the ignore / show-hidden feature (cmd+delete, cmd+y were too hidden and the bundle+title key was unreliable). Render the overlay from a fresh window snapshot on every show — no more stale tiles sliding into place after cmd-cmd. Drag and cmd+arrow now persist order through every known window, so newly-opened windows reliably append at the back.

## v0.2.2 — 2026-05-01

Drop phantom tiles instantly instead of fading them out: when a window was closed externally before you reopened the overlay, the cached tile briefly appeared and then animated away. It's now removed silently as soon as the fresh window list comes back.

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

