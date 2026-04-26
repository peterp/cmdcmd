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
    private var continueButton: NSButton!
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to ⌘ ⌘"
        w.center()
        w.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Two permissions to get started")
        heading.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(heading)

        let blurb = NSTextField(wrappingLabelWithString:
            "⌘ ⌘ needs your permission for the features below. Nothing leaves your machine."
        )
        blurb.font = NSFont.systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 472
        stack.addArrangedSubview(blurb)

        for p in permissions {
            let row = PermissionRow(permission: p) { [weak self] in
                p.request()
                NSWorkspace.shared.open(p.settingsURL)
                self?.refresh()
            }
            rows[p] = row
            stack.addArrangedSubview(row.view)
        }

        continueButton = NSButton(title: "Continue", target: self, action: #selector(didTapContinue))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSView()
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addSubview(continueButton)
        NSLayoutConstraint.activate([
            continueButton.trailingAnchor.constraint(equalTo: bottomRow.trailingAnchor),
            continueButton.topAnchor.constraint(equalTo: bottomRow.topAnchor),
            continueButton.bottomAnchor.constraint(equalTo: bottomRow.bottomAnchor),
            bottomRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        stack.addArrangedSubview(bottomRow)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            bottomRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        for r in rows.values {
            r.view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            r.view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        w.contentView = content
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        refresh()
    }

    @discardableResult
    private func refresh() -> Bool {
        var allGranted = true
        for p in permissions {
            let granted = p.granted()
            rows[p]?.setGranted(granted)
            if !granted { allGranted = false }
        }
        return allGranted
    }

    @objc private func didTapContinue() {
        guard refresh() else { return }
        window?.orderOut(nil)
        window = nil
        onComplete()
    }
}

private final class PermissionRow {
    let view: NSView
    private let dot: NSView
    private let button: NSButton
    private let permission: Permission

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
        rationale.preferredMaxLayoutWidth = 340

        let textStack = NSStackView(views: [title, rationale])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let btn = ButtonWrapper.make(title: "Grant", action: onGrant)
        btn.translatesAutoresizingMaskIntoConstraints = false
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
        button.title = granted ? "Granted" : "Grant"
        button.isEnabled = !granted
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
