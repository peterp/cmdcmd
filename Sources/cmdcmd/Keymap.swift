import AppKit

enum Action: String, Codable, Hashable {
    case pick
    case dismiss
    case moveLeft = "move-left"
    case moveRight = "move-right"
    case moveUp = "move-up"
    case moveDown = "move-down"
    case swapLeft = "swap-left"
    case swapRight = "swap-right"
    case swapUp = "swap-up"
    case swapDown = "swap-down"
    case ignore
    case toggleHidden = "toggle-hidden"
    case close
    case tagGreen = "tag-green"
    case tagBlue = "tag-blue"
    case tagRed = "tag-red"
    case tagYellow = "tag-yellow"
    case tagOrange = "tag-orange"
    case tagPurple = "tag-purple"
    case tagClear = "tag-clear"
    case pick1 = "pick-1"
    case pick2 = "pick-2"
    case pick3 = "pick-3"
    case pick4 = "pick-4"
    case pick5 = "pick-5"
    case pick6 = "pick-6"
    case pick7 = "pick-7"
    case pick8 = "pick-8"
    case pick9 = "pick-9"

    var doc: String {
        switch self {
        case .pick:         return "Pick the highlighted tile"
        case .dismiss:      return "Close the overlay (or zoom into the highlighted tile if a selection is active)"
        case .moveLeft:     return "Move selection left"
        case .moveRight:    return "Move selection right"
        case .moveUp:       return "Move selection up"
        case .moveDown:     return "Move selection down"
        case .swapLeft:     return "Swap with the tile on the left"
        case .swapRight:    return "Swap with the tile on the right"
        case .swapUp:       return "Swap with the tile above"
        case .swapDown:     return "Swap with the tile below"
        case .ignore:       return "Ignore / un-ignore the selected window"
        case .toggleHidden: return "Toggle the 'show hidden' view"
        case .close:        return "Close the selected window"
        case .tagGreen:     return "Tag green"
        case .tagBlue:      return "Tag blue"
        case .tagRed:       return "Tag red"
        case .tagYellow:    return "Tag yellow"
        case .tagOrange:    return "Tag orange"
        case .tagPurple:    return "Tag purple"
        case .tagClear:     return "Clear tag"
        case .pick1:        return "Pick tile 1"
        case .pick2:        return "Pick tile 2"
        case .pick3:        return "Pick tile 3"
        case .pick4:        return "Pick tile 4"
        case .pick5:        return "Pick tile 5"
        case .pick6:        return "Pick tile 6"
        case .pick7:        return "Pick tile 7"
        case .pick8:        return "Pick tile 8"
        case .pick9:        return "Pick tile 9"
        }
    }
}

struct Shortcut: Hashable {
    let mods: UInt
    let key: String

    static func parse(_ raw: String) -> Shortcut? {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for token in raw.lowercased().split(separator: "+").map(String.init) {
            switch token {
            case "cmd", "command":      flags.insert(.command)
            case "shift":                flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control":      flags.insert(.control)
            default:                     key = token
            }
        }
        guard !key.isEmpty else { return nil }
        return Shortcut(mods: flags.rawValue, key: key)
    }

    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = eventKey(event)
        guard !key.isEmpty else { return nil }
        return Shortcut(mods: flags.rawValue, key: key)
    }

    private static func eventKey(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 53: return "esc"
        case 49: return "space"
        case 36, 76: return "return"
        case 51: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: break
        }
        return (event.charactersIgnoringModifiers ?? "").lowercased()
    }
}

final class Keymap {
    private var bindings: [Shortcut: Action] = [:]

    init(overrides: [String: Action] = [:]) {
        for (raw, action) in Self.defaults {
            if let s = Shortcut.parse(raw) { bindings[s] = action }
        }
        for (raw, action) in overrides {
            if let s = Shortcut.parse(raw) { bindings[s] = action }
        }
    }

    func action(for event: NSEvent) -> Action? {
        guard let s = Shortcut.from(event: event) else { return nil }
        return bindings[s]
    }

    static let defaults: [String: Action] = [
        "esc": .dismiss,
        "return": .pick,
        "left": .moveLeft, "right": .moveRight, "up": .moveUp, "down": .moveDown,
        "a": .moveLeft, "d": .moveRight, "w": .moveUp, "s": .moveDown,
        "cmd+left": .swapLeft, "cmd+right": .swapRight, "cmd+up": .swapUp, "cmd+down": .swapDown,
        "cmd+delete": .ignore,
        "cmd+y": .toggleHidden,
        "cmd+w": .close,
        "opt+g": .tagGreen, "opt+b": .tagBlue, "opt+r": .tagRed, "opt+y": .tagYellow,
        "opt+o": .tagOrange, "opt+p": .tagPurple, "opt+0": .tagClear,
        "1": .pick1, "2": .pick2, "3": .pick3, "4": .pick4, "5": .pick5,
        "6": .pick6, "7": .pick7, "8": .pick8, "9": .pick9,
    ]
}
