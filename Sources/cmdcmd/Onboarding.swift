import AppKit
import ApplicationServices
import CoreGraphics

enum Permission {
    case screenRecording
    case accessibility

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility:   "Accessibility"
        }
    }

    var rationale: String {
        switch self {
        case .screenRecording:
            "Used to render live previews of your open windows in the overlay grid."
        case .accessibility:
            "Used to detect the ⌘⌘ chord and to raise the window you select."
        }
    }

    var pendingGuidance: String {
        switch self {
        case .screenRecording:
            "Find ⌘ ⌘ in the list and turn it on. We'll detect it and relaunch automatically."
        case .accessibility:
            "Find ⌘ ⌘ in the list and turn it on. We'll detect it and relaunch automatically."
        }
    }

    var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    func granted() -> Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility:   AXIsProcessTrusted()
        }
    }

    /// Triggers the OS prompt the first time; on subsequent calls it silently no-ops if denied.
    /// After denial the user must enable the permission manually in System Settings.
    func request() {
        switch self {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }
}

final class Onboarding {
    private var window: NSWindow?
    private var rows: [Permission: PermissionRow] = [:]
    private var pollTimer: Timer?
    private let onComplete: () -> Void
    private let permissions: [Permission] = [.screenRecording, .accessibility]

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    func showIfNeeded() -> Bool {
        if permissions.allSatisfy({ $0.granted() }) { return false }
        present()
        return true
    }

    private func present() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to ⌘ ⌘"
        w.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Two permissions to get started")
        heading.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(heading)

        let blurb = NSTextField(wrappingLabelWithString:
            "⌘ ⌘ needs your permission for the features below. Nothing leaves your machine."
        )
        blurb.font = NSFont.systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 432
        stack.addArrangedSubview(blurb)

        for p in permissions {
            let row = PermissionRow(permission: p) { [weak self] in
                self?.grantTapped(p)
            }
            rows[p] = row
            stack.addArrangedSubview(row.view)
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        for r in rows.values {
            r.view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            r.view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        w.contentView = content
        content.layoutSubtreeIfNeeded()
        w.setContentSize(content.fittingSize)
        w.center()
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        refresh()
        startPolling()
    }

    private func grantTapped(_ p: Permission) {
        p.request()
        NSWorkspace.shared.open(p.settingsURL)
        rows[p]?.setPending(true)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        var allGranted = true
        for p in permissions {
            let granted = p.granted()
            rows[p]?.setGranted(granted)
            if !granted { allGranted = false }
        }
        if allGranted {
            stopPolling()
            relaunchOrComplete()
        }
    }

    /// Accessibility (and Screen Recording, when it was here) often need a
    /// fresh process before global event taps / capture sessions register
    /// against the new TCC state. Relaunching is the only reliable way to get
    /// a clean install. If the relaunch fails for any reason, fall back to
    /// inline `onComplete` so the user isn't stuck.
    private func relaunchOrComplete() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        window?.orderOut(nil)
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                if app != nil, error == nil {
                    NSApp.terminate(nil)
                } else {
                    Log.write("onboarding relaunch failed: \(error?.localizedDescription ?? "nil"); continuing in-process")
                    self?.window = nil
                    self?.onComplete()
                }
            }
        }
    }
}

private final class PermissionRow {
    let view: NSView
    private let dot: NSView
    private let button: NSButton
    private let rationale: NSTextField
    private let permission: Permission
    private var pending = false

    init(permission: Permission, onGrant: @escaping () -> Void) {
        self.permission = permission

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        self.dot = dot

        let title = NSTextField(labelWithString: permission.title)
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)

        let rationale = NSTextField(wrappingLabelWithString: permission.rationale)
        rationale.font = NSFont.systemFont(ofSize: 12)
        rationale.textColor = .secondaryLabelColor
        rationale.preferredMaxLayoutWidth = 300
        self.rationale = rationale

        let textStack = NSStackView(views: [title, rationale])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let btn = ButtonWrapper.make(title: "Grant", action: onGrant)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setContentHuggingPriority(.required, for: .horizontal)
        self.button = btn

        container.addSubview(dot)
        container.addSubview(textStack)
        container.addSubview(btn)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -12),

            btn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            btn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
    }

    func setGranted(_ granted: Bool) {
        dot.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        if granted {
            pending = false
            button.title = "Granted"
            button.isEnabled = false
            rationale.stringValue = permission.rationale
        } else if pending {
            button.title = "Waiting…"
            button.isEnabled = false
        } else {
            button.title = "Grant"
            button.isEnabled = true
        }
    }

    func setPending(_ value: Bool) {
        pending = value
        if value {
            button.title = "Waiting…"
            button.isEnabled = false
            rationale.stringValue = permission.pendingGuidance
        }
    }
}

/// Plain target-action wrapper so the row can hand a closure to a button without subclassing NSButton.
private final class ButtonWrapper: NSObject {
    private let action: () -> Void
    private init(action: @escaping () -> Void) { self.action = action }

    static func make(title: String, action: @escaping () -> Void) -> NSButton {
        let wrapper = ButtonWrapper(action: action)
        let btn = NSButton(title: title, target: wrapper, action: #selector(fire))
        btn.bezelStyle = .rounded
        objc_setAssociatedObject(btn, &Self.key, wrapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return btn
    }

    @objc private func fire() { action() }
    private static var key: UInt8 = 0
}
