import AppKit
import CoreGraphics
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var settingsFactory: (() -> SettingsWindowController)?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var displayMode: DisplayMode = .dock

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let item = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func openSettings() {
        if displayMode == .hidden {
            NSApp.setActivationPolicy(.regular)
        }
        let controller = settingsWindow ?? settingsFactory?()
        settingsWindow = controller
        controller?.window?.delegate = self
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

    func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit cmdcmd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    func applyDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        switch mode {
        case .dock:
            statusItem = nil
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
            installStatusItem()
        case .hidden:
            statusItem = nil
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if displayMode == .hidden {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    private func installStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        statusItem?.button?.image = AppIcon.makePlaceholder()
        statusItem?.button?.image?.size = NSSize(width: 18, height: 18)
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let config = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        config.target = self
        menu.addItem(config)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit cmdcmd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
}

@main
struct CmdcmdApp {
    static var appConfig = Config.load()
    static let appDelegate = AppDelegate()
    static let tracker = SpaceTracker()
    static let overlay = Overlay(tracker: tracker, config: appConfig)
    static var trigger: AnyObject?

    static func main() {
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
        app.applicationIconImage = AppIcon.makePlaceholder()
        app.delegate = appDelegate
        app.finishLaunching()
        appDelegate.installMainMenu()
        appDelegate.applyDisplayMode(appConfig.displayMode)
        appDelegate.settingsFactory = {
            let controller = SettingsWindowController(config: appConfig)
            controller.onSave = { newConfig in
                appConfig = newConfig
                overlay.updateConfig(newConfig)
                appDelegate.applyDisplayMode(newConfig.displayMode)
                if !newConfig.minimalMode {
                    _ = Onboarding(onComplete: {}).showIfNeeded()
                }
            }
            return controller
        }

        let onboarding = Onboarding(onComplete: startApp)
        if appConfig.minimalMode || !onboarding.showIfNeeded() {
            startApp()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            overlay.shutdown()
        }

        app.run()
    }

    static func startApp() {
        if !appConfig.minimalMode {
            Task {
                _ = try? await SCShareableContent.current
            }
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

    static func dumpState(tracker: SpaceTracker) {
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
}
