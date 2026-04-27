import Foundation

struct Config: Codable {
    var animations: Bool
    var trigger: String?
    var bindings: [String: Action]

    var triggerSpec: String { trigger ?? "cmd-cmd" }

    static let `default` = Config(animations: true, trigger: nil, bindings: [:])

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cmdcmd/config.json")
    }

    static let template = """
    {
      "animations": true,
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

    static func ensureExists() throws -> URL {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }
}
