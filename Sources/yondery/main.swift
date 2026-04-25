import AppKit
import Carbon.HIToolbox

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

let tracker = SpaceTracker()
let overlay = Overlay()
let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_Y), modifiers: cmdShift) {
    overlay.toggle()
    dumpState(tracker: tracker)
}

dumpState(tracker: tracker)

func dumpState(tracker: SpaceTracker) {
    let spaces = tracker.spaces()
    let windows = tracker.windows()
    print("--- spaces (\(spaces.count)) ---")
    for s in spaces {
        let active = s.isActive ? " *" : ""
        print("  \(s.id) [\(s.type)] display=\(s.displayUUID.prefix(8))\(active)")
    }
    print("--- windows (\(windows.count)) ---")
    for w in windows where !w.ownerName.isEmpty {
        let space = w.spaceID.map(String.init) ?? "-"
        print("  \(w.windowID) space=\(space) \(w.ownerName) :: \(w.title)")
    }
    fflush(stdout)
}

app.run()
