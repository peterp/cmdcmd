import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel
    var onSave: ((Config) -> Void)? {
        get { model.onSave }
        set { model.onSave = newValue }
    }

    init(config: Config) {
        model = SettingsModel(config: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "cmdcmd Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SettingsModel: ObservableObject {
    @Published var animations: Bool { didSet { save() } }
    @Published var minimalMode: Bool { didSet { save() } }
    @Published var displayMode: DisplayMode { didSet { save() } }
    @Published var vimBindings: Bool { didSet { save() } }
    @Published var letterJump: Bool { didSet { save() } }
    private let trigger: String?
    @Published var status: String = ""
    var onSave: ((Config) -> Void)?

    init(config: Config) {
        animations = config.animations
        minimalMode = config.minimalMode
        displayMode = config.displayMode
        vimBindings = config.vimBindings
        letterJump = config.letterJump
        trigger = config.trigger
    }

    func save() {
        var config = Config.default
        config.animations = animations
        config.minimalMode = minimalMode
        config.displayMode = displayMode
        config.trigger = trigger
        config.vimBindings = vimBindings
        config.letterJump = letterJump
        do {
            try Config.save(config)
            onSave?(config)
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            Log.write("settings save failed: \(error)")
        }
    }

    func openConfig() {
        do {
            let url = try Config.ensureExists()
            NSWorkspace.shared.open(url)
        } catch {
            status = "Open failed: \(error.localizedDescription)"
            Log.write("openConfig failed: \(error)")
        }
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                settingsCard
                presenceCard
                inputCard
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .frame(minWidth: 560, minHeight: 440)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: AppIcon.makePlaceholder())
                .resizable()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("cmdcmd")
                    .font(.system(size: 25, weight: .semibold))
                Text("Fast app switching with a small native HUD.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsHeaderActionButton(title: "Open Config", helpText: "Open the JSON config file") {
                model.openConfig()
            }
        }
    }

    private var settingsCard: some View {
        SettingsCard {
            SettingsCardRow("Animations", subtitle: "Use smooth open, pick, and peek transitions.") {
                Toggle("", isOn: $model.animations)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsCardDivider()
            SettingsCardRow("Minimal icon mode", subtitle: "Show the LeaderKey-style app icon HUD instead of live window previews.") {
                Toggle("", isOn: $model.minimalMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var presenceCard: some View {
        SettingsCard {
            SettingsCardRow("Show app in", subtitle: "Hidden mode can be reopened from Launchpad, Spotlight, Finder, or by launching the app again.", controlWidth: 210) {
                Picker("", selection: $model.displayMode) {
                    Text("Dock").tag(DisplayMode.dock)
                    Text("Menu Bar").tag(DisplayMode.menuBar)
                    Text("Hidden").tag(DisplayMode.hidden)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var inputCard: some View {
        SettingsCard {
            SettingsCardRow("Vim navigation", subtitle: "Use h, j, k, and l to move between apps.") {
                Toggle("", isOn: $model.vimBindings)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsCardDivider()
            SettingsCardRow("First-letter app jump", subtitle: "Press an app’s first letter to select it; repeat to cycle matches.") {
                Toggle("", isOn: $model.letterJump)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }
}

private struct SettingsHeaderActionButton: View {
    let title: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help(helpText)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.38))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
        )
    }
}

private struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    @ViewBuilder let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, controlWidth: CGFloat? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let controlWidth {
                    trailing.frame(width: controlWidth, alignment: .trailing)
                } else {
                    trailing
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.22))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}
