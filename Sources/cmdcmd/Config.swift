import Foundation

struct Config: Codable {
    var animations: Bool
    var trigger: String?
    var bindings: [String: Action]
    var livePreviews: Bool?

    var triggerSpec: String { trigger ?? "cmd-cmd" }
    var livePreviewsEnabled: Bool { livePreviews ?? true }

    static let `default` = Config(animations: true, trigger: nil, bindings: [:], livePreviews: nil)

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cmdcmd/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = String(data: data, encoding: .utf8) else { return .default }
        let stripped = Self.stripLineComments(raw)
        guard let cleaned = stripped.data(using: .utf8) else { return .default }
        do {
            return try JSONDecoder().decode(Config.self, from: cleaned)
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
            try Self.template().write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }

    /// Strip `//` line comments while respecting double-quoted strings and
    /// escapes. Block comments are not supported.
    static func stripLineComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        var inString = false
        var escape = false
        while i < s.endIndex {
            let c = s[i]
            if inString {
                out.append(c)
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = s.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i = s.index(after: i)
                continue
            }
            if c == "/" {
                let next = s.index(after: i)
                if next < s.endIndex && s[next] == "/" {
                    while i < s.endIndex && s[i] != "\n" { i = s.index(after: i) }
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    static let bindingOrder: [(key: String, action: Action)] = [
        ("esc",        .dismiss),
        ("return",     .pick),
        ("left",       .moveLeft),
        ("right",      .moveRight),
        ("up",         .moveUp),
        ("down",       .moveDown),
        ("a",          .moveLeft),
        ("d",          .moveRight),
        ("w",          .moveUp),
        ("s",          .moveDown),
        ("cmd+left",   .swapLeft),
        ("cmd+right",  .swapRight),
        ("cmd+up",     .swapUp),
        ("cmd+down",   .swapDown),
        ("1",          .pick1),
        ("2",          .pick2),
        ("3",          .pick3),
        ("4",          .pick4),
        ("5",          .pick5),
        ("6",          .pick6),
        ("7",          .pick7),
        ("8",          .pick8),
        ("9",          .pick9),
        ("cmd+w",      .close),
        ("cmd+delete", .ignore),
        ("cmd+y",      .toggleHidden),
        ("opt+g",      .tagGreen),
        ("opt+b",      .tagBlue),
        ("opt+r",      .tagRed),
        ("opt+y",      .tagYellow),
        ("opt+o",      .tagOrange),
        ("opt+p",      .tagPurple),
        ("opt+0",      .tagClear),
    ]

    static func template() -> String {
        let keyWidth = bindingOrder.map { $0.key.count + 2 }.max() ?? 0
        let actionWidth = bindingOrder.map { $0.action.rawValue.count + 2 }.max() ?? 0
        var lines: [String] = []
        lines.append("// cmdcmd config — // line comments are stripped before parsing.")
        lines.append("// Edit and restart cmdcmd to apply changes.")
        lines.append("{")
        lines.append("  // Animate the show / pick zoom transitions. Set to false for instant.")
        lines.append("  \"animations\": true,")
        lines.append("")
        lines.append("  // Live tile previews. Set to false for static screenshots only —")
        lines.append("  // faster and lighter, especially with many windows open.")
        lines.append("  \"livePreviews\": true,")
        lines.append("")
        lines.append("  // What summons the overlay. \"cmd-cmd\" is the both-Command-keys chord.")
        lines.append("  // Anything else is a normal hotkey: \"cmd+shift+space\", \"f13\", etc.")
        lines.append("  \"trigger\": \"cmd-cmd\",")
        lines.append("")
        lines.append("  // Default key bindings shown below — edit, remove, or add to taste.")
        lines.append("  // Modifier tokens: cmd, shift, opt (or option/alt), ctrl.")
        lines.append("  // Special keys:    esc, space, return, delete, left, right, up, down.")
        lines.append("  \"bindings\": {")
        for (idx, entry) in bindingOrder.enumerated() {
            let suffix = idx == bindingOrder.count - 1 ? " " : ","
            let keyLit = "\"\(entry.key)\":".padding(toLength: keyWidth + 1, withPad: " ", startingAt: 0)
            let actionLit = "\"\(entry.action.rawValue)\"\(suffix)".padding(toLength: actionWidth + 2, withPad: " ", startingAt: 0)
            lines.append("    \(keyLit) \(actionLit) // \(entry.action.doc)")
        }
        lines.append("  }")
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
