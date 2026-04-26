import AppKit
import CoreGraphics
import ScreenCaptureKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()

_ = CGRequestScreenCaptureAccess()
Task {
    _ = try? await SCShareableContent.current
}

let tracker = SpaceTracker()
let overlay = Overlay(tracker: tracker)

let chord = CmdChord {
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
