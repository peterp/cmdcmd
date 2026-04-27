import AppKit
import CoreGraphics
import ScreenCaptureKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-iconset"), i + 1 < args.count {
    let url = URL(fileURLWithPath: args[i + 1])
    do {
        try AppIcon.writeIconset(to: url)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-iconset failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.applicationIconImage = AppIcon.makePlaceholder()
app.finishLaunching()

let tracker = SpaceTracker()
let overlay = Overlay(tracker: tracker)
var chord: CmdChord?

func startApp() {
    Task {
        _ = try? await SCShareableContent.current
    }
    chord = CmdChord {
        overlay.toggle()
        dumpState(tracker: tracker)
    }
    dumpState(tracker: tracker)
}

let onboarding = Onboarding(onComplete: startApp)
if !onboarding.showIfNeeded() {
    startApp()
}

NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    overlay.shutdown()
}

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
