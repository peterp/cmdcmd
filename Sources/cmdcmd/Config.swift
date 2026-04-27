import Foundation

enum DisplayMode: String, Codable, CaseIterable {
    case dock
    case menuBar = "menu-bar"
    case hidden
}

struct Config: Codable {
    var animations: Bool
    var minimalMode: Bool
    var displayMode: DisplayMode
    var trigger: String?
    var bindings: [String: Action]

    var triggerSpec: String { trigger ?? "cmd-cmd" }

    enum CodingKeys: String, CodingKey {
        case animations, minimalMode, displayMode, trigger, bindings
    }

    init(animations: Bool, minimalMode: Bool, displayMode: DisplayMode, trigger: String?, bindings: [String: Action]) {
        self.animations = animations
        self.minimalMode = minimalMode
        self.displayMode = displayMode
        self.trigger = trigger
        self.bindings = bindings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        animations = try c.decodeIfPresent(Bool.self, forKey: .animations) ?? true
        minimalMode = try c.decodeIfPresent(Bool.self, forKey: .minimalMode) ?? true
        displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .dock
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        bindings = try c.decodeIfPresent([String: Action].self, forKey: .bindings) ?? [:]
    }

    static let `default` = Config(animations: true, minimalMode: true, displayMode: .dock, trigger: nil, bindings: [:])

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cmdcmd/config.json")
    }

    static let template = """
    {
      "animations": true,
      "minimalMode": true,
      "displayMode": "dock",
      "trigger": "cmd-cmd",
      "bindings": {
      }
    }
    """

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return .default }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.write("config parse failed at \(fileURL.path): \(error)")
            return .default
        }
    }

    static func save(_ config: Config) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }

    static func ensureExists() throws -> URL {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }
}
