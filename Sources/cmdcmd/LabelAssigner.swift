import CoreGraphics
import Foundation

/// Assigns short typeable prefixes (e.g. "wa", "cc", "cal") to tiles for
/// letter-pick mode. Existing assignments are sticky for the lifetime of the
/// process: once a window has a prefix, closing or opening other windows
/// never reshuffles it.
final class LabelAssigner {
    private struct Entry {
        let prefix: String
        let appKey: String
    }

    private var entries: [CGWindowID: Entry] = [:]

    /// Compute prefixes for the given tiles in their grid order. Tiles already
    /// in the assignment map keep their existing prefix; new tiles claim the
    /// next non-colliding prefix.
    func assign(_ tiles: [Tile]) -> [CGWindowID: String] {
        let presentIDs = Set(tiles.map { CGWindowID($0.scWindow.windowID) })
        entries = entries.filter { presentIDs.contains($0.key) }

        var used: [String: String] = [:] // prefix -> appKey
        for (_, e) in entries { used[e.prefix] = e.appKey }

        for tile in tiles {
            let id = CGWindowID(tile.scWindow.windowID)
            if entries[id] != nil { continue }
            let appName = tile.scWindow.owningApplication?.applicationName ?? "?"
            let appKey = tile.scWindow.owningApplication?.bundleIdentifier ?? appName
            let natural = Self.naturalPrefix(appName: appName)

            guard !natural.isEmpty else { continue }

            if used[natural] == nil {
                entries[id] = Entry(prefix: natural, appKey: appKey)
                used[natural] = appKey
                continue
            }

            let conflictingApp = used[natural] ?? ""
            let firstChar = String(natural.prefix(1))

            if conflictingApp == appKey {
                if let pick = Self.firstAvailable(
                    candidates: Self.homeRow.map { firstChar + String($0) },
                    used: used.keys
                ) {
                    entries[id] = Entry(prefix: pick, appKey: appKey)
                    used[pick] = appKey
                }
            } else {
                let extended = Self.naturalThirdChar(appName: appName).map { natural + String($0) }
                if let extended, used[extended] == nil {
                    entries[id] = Entry(prefix: extended, appKey: appKey)
                    used[extended] = appKey
                } else if let pick = Self.firstAvailable(
                    candidates: Self.homeRow.map { natural + String($0) },
                    used: used.keys
                ) {
                    entries[id] = Entry(prefix: pick, appKey: appKey)
                    used[pick] = appKey
                }
            }
        }

        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value.prefix) })
    }

    private static let homeRow: [Character] = ["j", "k", "l", "f", "d", "s", "a", "g", "h"]

    private static func firstAvailable<S: Sequence>(candidates: [String], used: S) -> String? where S.Element == String {
        let usedSet = Set(used)
        return candidates.first { !usedSet.contains($0) }
    }

    static func naturalPrefix(appName: String) -> String {
        let tokens = tokenize(appName)
        if tokens.count >= 2 {
            let a = tokens[0].first.map { String($0) } ?? ""
            let b = tokens[1].first.map { String($0) } ?? ""
            return (a + b).lowercased()
        }
        if let only = tokens.first {
            if only.count >= 2 {
                return String(only.prefix(2)).lowercased()
            }
            if let c = only.first {
                return String([c, c]).lowercased()
            }
        }
        return ""
    }

    private static func naturalThirdChar(appName: String) -> Character? {
        let tokens = tokenize(appName)
        guard let first = tokens.first else { return nil }
        if tokens.count >= 2 {
            // Two-token prefix used letters from each — extend with the second
            // letter of the first token (e.g. "cc" → "cl" for Claude Code is
            // ambiguous; we instead extend within token 1: "Calendar Code"
            // would land at "cal" when colliding with "cap …"). Falls back to
            // token-2 second letter if token-1 has only one char.
            if first.count >= 2 {
                let idx = first.index(first.startIndex, offsetBy: 1)
                return Character(first[idx].lowercased())
            }
            if tokens[1].count >= 2 {
                let idx = tokens[1].index(tokens[1].startIndex, offsetBy: 1)
                return Character(tokens[1][idx].lowercased())
            }
            return nil
        }
        guard first.count >= 3 else { return nil }
        let idx = first.index(first.startIndex, offsetBy: 2)
        return Character(first[idx].lowercased())
    }

    /// Split `s` into tokens on whitespace and camelCase boundaries.
    /// "Claude Code" → ["Claude", "Code"]
    /// "WhatsApp"    → ["Whats", "App"]
    /// "VSCodium"    → ["VS", "Codium"]
    static func tokenize(_ s: String) -> [String] {
        // Strip invisible formatting scalars (e.g. WhatsApp's CFBundleDisplayName
        // begins with U+200E LEFT-TO-RIGHT MARK) so they can't sneak into the
        // prefix as a zero-width first "letter".
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            let cat = scalar.properties.generalCategory
            return cat != .control && cat != .format
        }))
        return cleaned.split(whereSeparator: { $0.isWhitespace })
            .flatMap { camelSplit(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func camelSplit(_ word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let chars = Array(word)
        var splits: [Int] = [0]
        for i in 1..<chars.count {
            let prev = chars[i - 1]
            let cur = chars[i]
            if prev.isLowercase && cur.isUppercase {
                splits.append(i)
                continue
            }
            if prev.isUppercase && cur.isUppercase,
               i + 1 < chars.count, chars[i + 1].isLowercase {
                splits.append(i)
                continue
            }
        }
        splits.append(chars.count)
        var tokens: [String] = []
        for k in 0..<splits.count - 1 {
            let part = String(chars[splits[k]..<splits[k + 1]])
            if !part.isEmpty { tokens.append(part) }
        }
        return tokens
    }
}
