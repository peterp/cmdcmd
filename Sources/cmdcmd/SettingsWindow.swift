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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
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
    private var base: Config
    @Published var status: String = ""
    var onSave: ((Config) -> Void)?

    init(config: Config) {
        animations = config.animations
        livePreviews = config.livePreviewsEnabled
        base = config
    }

    func save() {
        var config = base
        config.animations = animations
        config.livePreviews = livePreviews
        do {
            try Config.patchOnDisk([
                ("animations", animations ? "true" : "false"),
                ("livePreviews", livePreviews ? "true" : "false"),
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
        .frame(minWidth: 420, minHeight: 280)
    }
}
