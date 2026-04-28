import Foundation

enum DisplayMode: String, Codable, CaseIterable {
    case dock
    case menuBar = "menu-bar"
    case hidden
}

struct Config: Codable {
    var animations: Bool
    var trigger: String?
    var bindings: [String: Action]
    var livePreviews: Bool?
    var displayMode: DisplayMode?
    var letterJump: Bool?

    var triggerSpec: String { trigger ?? "cmd-cmd" }
    var livePreviewsEnabled: Bool { livePreviews ?? true }
    var displayModeOrDefault: DisplayMode { displayMode ?? .dock }
    var letterJumpEnabled: Bool { letterJump ?? true }

    static let `default` = Config(animations: true, trigger: nil, bindings: [:], livePreviews: nil, displayMode: nil, letterJump: nil)

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

    /// Patch top-level keys in the existing config file in-place, preserving
    /// comments, key order, and formatting. Each value is written as the
    /// literal JSON token in `updates` (e.g. `"true"`, `"false"`, `"null"`).
    /// If the file is missing or unreadable, falls back to writing the
    /// template + the requested updates.
    static func patchOnDisk(_ updates: [(key: String, value: String)]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: fileURL, encoding: .utf8))
        var text = existing ?? Self.template()

        for (key, valueLiteral) in updates {
            text = patch(text: text, key: key, valueLiteral: valueLiteral)
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Replace the value of `key` at the root object's top level. Inserts
    /// the key before the closing `}` if it doesn't exist.
    static func patch(text: String, key: String, valueLiteral: String) -> String {
        if let range = topLevelValueRange(in: text, key: key) {
            return text.replacingCharacters(in: range, with: valueLiteral)
        }
        return insertTopLevelKey(text: text, key: key, valueLiteral: valueLiteral)
    }

    /// Locate the value range for a top-level `"key": <value>` pair.
    /// Range covers the value text only, excluding trailing comma/whitespace.
    private static func topLevelValueRange(in text: String, key: String) -> Range<String.Index>? {
        var i = text.startIndex
        var depth = 0
        var inString = false
        var escape = false

        while i < text.endIndex {
            let c = text[i]
            if escape { escape = false; i = text.index(after: i); continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i); continue
            }
            if c == "/" {
                let n = text.index(after: i)
                if n < text.endIndex && text[n] == "/" {
                    while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
            }
            if c == "\"" {
                let keyOpen = text.index(after: i)
                var j = keyOpen
                var localEscape = false
                while j < text.endIndex {
                    let cc = text[j]
                    if localEscape { localEscape = false; j = text.index(after: j); continue }
                    if cc == "\\" { localEscape = true; j = text.index(after: j); continue }
                    if cc == "\"" { break }
                    j = text.index(after: j)
                }
                let keyClose = j
                let next = j < text.endIndex ? text.index(after: j) : j

                if depth == 1 {
                    let keyText = String(text[keyOpen..<keyClose])
                    if keyText == key,
                       let valueRange = valueRangeAfterColon(in: text, from: next) {
                        return valueRange
                    }
                }
                i = next
                continue
            }
            if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" { depth -= 1 }
            i = text.index(after: i)
        }
        return nil
    }

    private static func valueRangeAfterColon(in text: String, from start: String.Index) -> Range<String.Index>? {
        var i = start
        while i < text.endIndex && text[i].isWhitespace { i = text.index(after: i) }
        guard i < text.endIndex, text[i] == ":" else { return nil }
        i = text.index(after: i)
        while i < text.endIndex && text[i].isWhitespace { i = text.index(after: i) }
        let valueStart = i

        var depth = 0
        var inString = false
        var escape = false
        while i < text.endIndex {
            let c = text[i]
            if escape { escape = false; i = text.index(after: i); continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i); continue
            }
            if c == "\"" { inString = true; i = text.index(after: i); continue }
            if c == "/" {
                let n = text.index(after: i)
                if n < text.endIndex && text[n] == "/" {
                    while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
            }
            if c == "{" || c == "[" { depth += 1; i = text.index(after: i); continue }
            if c == "}" || c == "]" {
                if depth == 0 { break }
                depth -= 1; i = text.index(after: i); continue
            }
            if depth == 0 && c == "," { break }
            i = text.index(after: i)
        }
        var valueEnd = i
        while valueEnd > valueStart {
            let prev = text.index(before: valueEnd)
            if text[prev].isWhitespace { valueEnd = prev } else { break }
        }
        return valueStart..<valueEnd
    }

    /// Insert a new top-level key just before the root object's closing `}`.
    private static func insertTopLevelKey(text: String, key: String, valueLiteral: String) -> String {
        var lastTopBraceClose: String.Index?
        var i = text.startIndex
        var depth = 0
        var inString = false
        var escape = false
        while i < text.endIndex {
            let c = text[i]
            if escape { escape = false; i = text.index(after: i); continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i); continue
            }
            if c == "/" {
                let n = text.index(after: i)
                if n < text.endIndex && text[n] == "/" {
                    while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
            }
            if c == "\"" { inString = true; i = text.index(after: i); continue }
            if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" {
                if depth == 1 && c == "}" { lastTopBraceClose = i }
                depth -= 1
            }
            i = text.index(after: i)
        }
        guard let close = lastTopBraceClose else { return text }

        // Find indent of the closing brace's line.
        var lineStart = close
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev] == "\n" { break }
            lineStart = prev
        }
        let indent = String(text[lineStart..<close])

        // Walk back past whitespace/comments to find the previous non-comment, non-whitespace char.
        // If it's not `,` and not `{`, we need to add a comma to the previous entry.
        var scan = close
        var needsTrailingCommaOnPrev = false
        var sawNonSpace = false
        while scan > text.startIndex {
            let prev = text.index(before: scan)
            let pc = text[prev]
            if pc == "\n" || pc == " " || pc == "\t" {
                scan = prev; continue
            }
            // Walk back over a `// ...` line comment trailing on the same line.
            if pc == "\n" { scan = prev; continue }
            // Detect comment: walk to start of line, see if it begins with //.
            var ls = prev
            while ls > text.startIndex {
                let p2 = text.index(before: ls)
                if text[p2] == "\n" { break }
                ls = p2
            }
            let line = text[ls...prev]
            if let slash = line.firstIndex(of: "/"),
               text.index(after: slash) <= prev,
               text[slash] == "/", text[text.index(after: slash)] == "/" {
                scan = ls
                continue
            }
            sawNonSpace = true
            if pc != "," && pc != "{" {
                needsTrailingCommaOnPrev = true
            }
            break
        }
        _ = sawNonSpace

        let entry = "\(indent)  \"\(key)\": \(valueLiteral)"
        var output = text
        if needsTrailingCommaOnPrev {
            // Insert "," at `scan` (right after the last non-ws/comment char).
            output.insert(",", at: scan)
        }
        // Recompute close index after potential insert.
        let newClose = needsTrailingCommaOnPrev ? output.index(close, offsetBy: 1) : close
        var lineStart2 = newClose
        while lineStart2 > output.startIndex {
            let prev = output.index(before: lineStart2)
            if output[prev] == "\n" { break }
            lineStart2 = prev
        }
        output.insert(contentsOf: entry + "\n", at: lineStart2)
        return output
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
