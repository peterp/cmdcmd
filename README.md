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
| `space` (hold) | Zoom selected tile |
| click / drag | Pick or drag-to-reorder |
| ⌘ + arrow | Swap selected tile with neighbour |
| ⌘F | Enter focus mode (raise window, forward keys, overlay stays) |
| ⌘`esc` | Exit focus mode |
| ⌘`delete` | Ignore / un-ignore selected window |
| ⌘Y | Toggle "show ignored" view |
| `esc` | Dismiss overlay |

Tile order, ignored windows, and ignore state persist across launches via `UserDefaults`. Idle windows (no draw activity for ~0.5s) get a subtle indicator.

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

On first run macOS will prompt for:

- **Screen Recording** — for live tile previews (ScreenCaptureKit).
- **Accessibility** — for the ⌘⌘ chord listener and to raise / forward keys to the chosen window.

Both are required; the app is useless without them.

## Layout

```
Sources/cmdcmd/
  main.swift          # entry point, wires Hotkey + CmdChord into Overlay
  Overlay.swift       # overlay window, tile grid, selection, focus mode
  Tile.swift          # per-window SCStream preview layer
  GridLayout.swift    # grid sizing for N tiles at the screen aspect ratio
  CmdChord.swift      # left+right Command chord detector
  Hotkey.swift        # Carbon RegisterEventHotKey wrapper
  SpaceTracker.swift  # private CGS/SkyLight space + window enumeration
  Log.swift           # stderr logger
Resources/Info.plist  # bundle metadata
build-app.sh          # swift build → .app bundle + ad-hoc codesign
```

## Status

Pre-release.
