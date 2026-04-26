import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    var onEscape: (() -> Void)?
    var onArrow: ((Int, Int) -> Void)?
    var onEnter: (() -> Void)?
    var onSpaceDown: (() -> Void)?
    var onSpaceUp: (() -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onDigit: ((Int) -> Void)?
    var onSwap: ((Int, Int) -> Void)?
    var onIgnore: (() -> Void)?
    var onToggleIgnoredView: (() -> Void)?
    var onTagColor: ((String?) -> Void)?
    private var momentaryPeek = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let opt = event.modifierFlags.contains(.option)
        if opt && !cmd {
            switch event.keyCode {
            case 5:  onTagColor?("green");  return
            case 11: onTagColor?("blue");   return
            case 15: onTagColor?("red");    return
            case 16: onTagColor?("yellow"); return
            case 31: onTagColor?("orange"); return
            case 35: onTagColor?("purple"); return
            case 29: onTagColor?(nil);      return
            default: break
            }
        }
        switch event.keyCode {
        case 53: onEscape?(); return
        case 49:
            if event.isARepeat { return }
            momentaryPeek = true
            onSpaceDown?()
            return
        case 36, 76: onEnter?(); return
        case 123 where cmd: onSwap?(-1, 0); return
        case 124 where cmd: onSwap?(1, 0); return
        case 125 where cmd: onSwap?(0, 1); return
        case 126 where cmd: onSwap?(0, -1); return
        case 123: onArrow?(-1, 0); return
        case 124: onArrow?(1, 0); return
        case 125: onArrow?(0, 1); return
        case 126: onArrow?(0, -1); return
        case 51 where cmd: onIgnore?(); return
        case 34 where cmd: onToggleIgnoredView?(); return
        default: break
        }
        if !cmd, let ch = event.charactersIgnoringModifiers, ch.count == 1,
           let n = Int(ch), (1...9).contains(n) {
            onDigit?(n)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            if momentaryPeek {
                momentaryPeek = false
                onSpaceUp?()
            }
            return
        }
    }

    func resetMomentaryPeek() {
        momentaryPeek = false
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }
}
