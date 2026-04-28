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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "cmdcmd Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SettingsModel: ObservableObject {
    @Published var animations: Bool { didSet { save() } }
    @Published var livePreviews: Bool { didSet { save() } }
    @Published var displayMode: DisplayMode { didSet { save() } }
    @Published var letterJump: Bool { didSet { save() } }
    @Published var usageOrdering: Bool { didSet { save() } }
    private var base: Config
    @Published var status: String = ""
    var onSave: ((Config) -> Void)?

    init(config: Config) {
        animations = config.animations
        livePreviews = config.livePreviewsEnabled
        displayMode = config.displayModeOrDefault
        letterJump = config.letterJumpEnabled
        usageOrdering = config.usageOrderingEnabled
        base = config
    }

    func save() {
        var config = base
        config.animations = animations
        config.livePreviews = livePreviews
        config.displayMode = displayMode
        config.letterJump = letterJump
        config.usageOrdering = usageOrdering
        do {
            try Config.patchOnDisk([
                ("animations", animations ? "true" : "false"),
                ("livePreviews", livePreviews ? "true" : "false"),
                ("displayMode", "\"\(displayMode.rawValue)\""),
                ("letterJump", letterJump ? "true" : "false"),
                ("usageOrdering", usageOrdering ? "true" : "false"),
            ])
            base = config
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
        VStack(alignment: .leading, spacing: 18) {
            Text("cmdcmd")
                .font(.system(size: 22, weight: .semibold))

            Toggle(isOn: $model.animations) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Animations").font(.system(size: 13, weight: .medium))
                    Text("Smooth open, pick, and peek transitions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $model.livePreviews) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live previews").font(.system(size: 13, weight: .medium))
                    Text("Stream live frames per tile. Off uses static screenshots — lighter with many windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $model.letterJump) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("First-letter app jump").font(.system(size: 13, weight: .medium))
                    Text("Hold ⌃ (Control) + an app's first letter to select it; repeat to cycle matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $model.usageOrdering) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Order tiles by recent app usage").font(.system(size: 13, weight: .medium))
                    Text("Most recently used apps come first. Overrides drag-to-reorder across sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Text("Show app in").font(.system(size: 13, weight: .medium))
                Picker("", selection: $model.displayMode) {
                    Text("Dock").tag(DisplayMode.dock)
                    Text("Menu Bar").tag(DisplayMode.menuBar)
                    Text("Hidden").tag(DisplayMode.hidden)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Hidden mode keeps the app running with no Dock or menu bar UI. Re-launch cmdcmd.app to bring Settings back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("Open Config…") { model.openConfig() }
                Spacer()
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 480)
    }
}
