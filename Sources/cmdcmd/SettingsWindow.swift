import AppKit

final class SettingsWindowController: NSWindowController {
    private let animationsButton = NSButton(checkboxWithTitle: "Animations", target: nil, action: nil)
    private let minimalButton = NSButton(checkboxWithTitle: "Minimal icon mode", target: nil, action: nil)
    private let displayModeControl = NSSegmentedControl(labels: ["Dock", "Menu Bar", "Hidden"], trackingMode: .selectOne, target: nil, action: nil)
    private let triggerField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var config: Config
    var onSave: ((Config) -> Void)?

    init(config: Config) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 390),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "cmdcmd Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        build()
        load(config)
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        guard let content = window?.contentView else { return }
        let visual = NSVisualEffectView()
        visual.blendingMode = .behindWindow
        visual.material = .hudWindow
        visual.state = .active
        visual.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(visual)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let icon = NSImageView(image: AppIcon.makePlaceholder())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 14
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        header.addArrangedSubview(icon)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let title = NSTextField(labelWithString: "cmdcmd")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.textColor = .labelColor
        let subtitle = NSTextField(labelWithString: "Fast window switching, tuned for how visible you want the app to be.")
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(title)
        titleStack.addArrangedSubview(subtitle)
        header.addArrangedSubview(titleStack)
        root.addArrangedSubview(header)

        let behaviorCard = makeCard()
        let behaviorStack = makeCardStack(in: behaviorCard)
        behaviorStack.addArrangedSubview(makeSectionTitle("Behavior"))
        animationsButton.target = self
        animationsButton.action = #selector(save)
        animationsButton.controlSize = .large
        behaviorStack.addArrangedSubview(makeSettingRow(title: "Motion", detail: "Use smooth open, pick, and peek transitions.", control: animationsButton))
        minimalButton.target = self
        minimalButton.action = #selector(save)
        minimalButton.controlSize = .large
        behaviorStack.addArrangedSubview(makeSettingRow(title: "Minimal mode", detail: "Show app icons instead of live window previews.", control: minimalButton))
        root.addArrangedSubview(behaviorCard)

        let presenceCard = makeCard()
        let presenceStack = makeCardStack(in: presenceCard)
        presenceStack.addArrangedSubview(makeSectionTitle("Presence"))
        displayModeControl.segmentStyle = .capsule
        displayModeControl.controlSize = .large
        displayModeControl.target = self
        displayModeControl.action = #selector(save)
        presenceStack.addArrangedSubview(makeSettingRow(title: "Show app in", detail: "Hidden mode can be reopened from Launchpad, Spotlight, Finder, or by launching the app again.", control: displayModeControl))
        root.addArrangedSubview(presenceCard)

        let shortcutCard = makeCard()
        let shortcutStack = makeCardStack(in: shortcutCard)
        shortcutStack.addArrangedSubview(makeSectionTitle("Shortcut"))
        triggerField.placeholderString = "cmd-cmd"
        triggerField.target = self
        triggerField.action = #selector(save)
        triggerField.controlSize = .large
        triggerField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        triggerField.lineBreakMode = .byTruncatingTail
        triggerField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        shortcutStack.addArrangedSubview(makeSettingRow(title: "Trigger", detail: "Restart after changing this shortcut.", control: triggerField))
        root.addArrangedSubview(shortcutCard)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.keyEquivalent = "\r"
        let configButton = NSButton(title: "Open Config…", target: self, action: #selector(openConfig))
        configButton.bezelStyle = .rounded
        configButton.controlSize = .large
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        footer.addArrangedSubview(saveButton)
        footer.addArrangedSubview(configButton)
        footer.addArrangedSubview(statusLabel)
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            visual.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visual.topAnchor.constraint(equalTo: content.topAnchor),
            visual.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
        ])
    }

    private func makeCard() -> NSView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 18
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        view.widthAnchor.constraint(equalToConstant: 444).isActive = true
        return view
    }

    private func makeCardStack(in view: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeSettingRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 412).isActive = true

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(detailLabel)
        row.addArrangedSubview(text)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        return row
    }

    private func load(_ config: Config) {
        animationsButton.state = config.animations ? .on : .off
        minimalButton.state = config.minimalMode ? .on : .off
        switch config.displayMode {
        case .dock: displayModeControl.selectedSegment = 0
        case .menuBar: displayModeControl.selectedSegment = 1
        case .hidden: displayModeControl.selectedSegment = 2
        }
        triggerField.stringValue = config.triggerSpec
    }

    @objc private func save() {
        config.animations = animationsButton.state == .on
        config.minimalMode = minimalButton.state == .on
        switch displayModeControl.selectedSegment {
        case 1: config.displayMode = .menuBar
        case 2: config.displayMode = .hidden
        default: config.displayMode = .dock
        }
        let rawTrigger = triggerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.trigger = rawTrigger.isEmpty || rawTrigger == "cmd-cmd" ? nil : rawTrigger
        do {
            try Config.save(config)
            onSave?(config)
            statusLabel.stringValue = "Saved. Trigger changes apply after restart."
        } catch {
            statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
            Log.write("settings save failed: \(error)")
        }
    }

    @objc private func openConfig() {
        do {
            let url = try Config.ensureExists()
            NSWorkspace.shared.open(url)
        } catch {
            statusLabel.stringValue = "Open failed: \(error.localizedDescription)"
            Log.write("openConfig failed: \(error)")
        }
    }
}
