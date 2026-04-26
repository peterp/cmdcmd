# cmd & cmd

A keyboard-first window switcher for macOS. Press both ⌘ keys at once to fan every visible window out into a grid of live previews, then jump straight to the one you want.

Requires macOS 14+.

## Trigger

**⌘ + ⌘** — tap left and right Command at the same time (no other key in between). Tap again, or press `esc`, to dismiss.

## Keybindings (overlay)

| Key | Action |
|---|---|
| arrow keys | Move selection |
| `1`–`9` | Pick that tile |
| `return` | Pick selected tile |
| `space` (hold) | Peek (zoom selected tile while held) |
| ⌘`space` (hold) | Peek; on release, enter focus mode on the selected window |
| click / drag | Pick or drag-to-reorder |
| ⌘ + arrow | Swap selected tile with neighbour in that direction |
| ⌘`esc` | Exit focus mode |
| ⌘`delete` | Ignore / un-ignore selected window |
| ⌘Y | Toggle "show hidden" view |
| `esc` | Dismiss overlay |

Tile order and ignored windows persist across launches via `UserDefaults`. Idle windows (no draw activity for ~0.5s) get a subtle indicator. The "show hidden" view displays every window — ignored ones at reduced opacity — so you can un-ignore them.

## Build

```sh
./build-app.sh           # debug build → cmdcmd.app
./build-app.sh release   # release build
open cmdcmd.app
```

Or run the binary directly:

```sh
swift build
.build/debug/cmdcmd
```

## Permissions

On first launch you'll see an onboarding window explaining what the app needs and why:

- **Screen Recording** — for live tile previews (ScreenCaptureKit).
- **Accessibility** — for the ⌘⌘ chord listener and to raise / forward keys to the chosen window.

Each row has a Grant button that opens the matching pane in System Settings. Click Continue once both are toggled on. Both are required; the app does nothing without them.

The app shows in the Dock as `⌘ ⌘` so you can quit it the normal way.

## Layout

```
Sources/cmdcmd/
  main.swift          # entry point, wires onboarding + CmdChord into Overlay
  AppIcon.swift       # runtime-drawn placeholder Dock icon
  Onboarding.swift    # first-run permission window
  Overlay.swift       # overlay window, tile grid, selection, focus mode
  OverlayView.swift   # NSWindow + NSView event router for the overlay
  HintPill.swift      # bottom-center mode-hint label
  Tile.swift          # per-window SCStream preview layer
  GridLayout.swift    # grid sizing for N tiles at the screen aspect ratio
  CmdChord.swift      # left+right Command chord detector
  SpaceTracker.swift  # private CGS/SkyLight space + window enumeration
  Log.swift           # stderr logger
Resources/Info.plist  # bundle metadata
build-app.sh          # swift build → .app bundle + ad-hoc codesign
```

## Status

Pre-release.
