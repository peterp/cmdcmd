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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func openConfig() {
        do {
            let url = try Config.ensureExists()
            NSWorkspace.shared.open(url)
        } catch {
            Log.write("openConfig failed: \(error)")
        }
    }
}

let appDelegate = AppDelegate()
app.delegate = appDelegate
app.finishLaunching()

_ = try? Config.ensureExists()
let appConfig = Config.load()
let tracker = SpaceTracker()
let overlay = Overlay(tracker: tracker, config: appConfig)
var trigger: AnyObject?

func startApp() {
    Task {
        _ = try? await SCShareableContent.current
    }
    let fire = {
        overlay.toggle()
        dumpState(tracker: tracker)
    }
    if appConfig.triggerSpec.lowercased() == "cmd-cmd" {
        trigger = CmdChord(handler: fire)
    } else if let monitor = HotkeyMonitor(spec: appConfig.triggerSpec, handler: fire) {
        trigger = monitor
        Log.write("trigger = \(appConfig.triggerSpec)")
    } else {
        Log.write("trigger spec '\(appConfig.triggerSpec)' invalid; falling back to cmd-cmd")
        trigger = CmdChord(handler: fire)
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
