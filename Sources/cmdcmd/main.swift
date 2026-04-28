import AppKit
import CoreGraphics
import ScreenCaptureKit
import Sparkle

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var settingsFactory: (() -> SettingsWindowController)?
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return buildAppMenu()
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let openItem = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let checkItem = NSMenuItem(title: "Check for Updates…",
                                   action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                   keyEquivalent: "")
        checkItem.target = updaterController
        menu.addItem(checkItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit cmdcmd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func applyDisplayMode(_ mode: DisplayMode) {
        switch mode {
        case .dock:
            removeStatusItem()
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
            installStatusItem()
        case .hidden:
            removeStatusItem()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let icon = NSImage(systemSymbolName: "command", accessibilityDescription: "cmdcmd")
            icon?.isTemplate = true
            item.button?.image = icon
            item.menu = buildAppMenu()
            statusItem = item
        }
    }

    private func removeStatusItem() {
        if let s = statusItem {
            NSStatusBar.system.removeStatusItem(s)
        }
        statusItem = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    @objc func openSettings() {
        let controller = settingsController ?? settingsFactory?()
        settingsController = controller
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
var appConfig = Config.load()
appDelegate.applyDisplayMode(appConfig.displayModeOrDefault)
let tracker = SpaceTracker()
let overlay = Overlay(tracker: tracker, config: appConfig)
var trigger: AnyObject?

appDelegate.settingsFactory = {
    let controller = SettingsWindowController(config: appConfig)
    controller.onSave = { newConfig in
        appConfig = newConfig
        overlay.updateConfig(newConfig)
        appDelegate.applyDisplayMode(newConfig.displayModeOrDefault)
    }
    return controller
}

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
