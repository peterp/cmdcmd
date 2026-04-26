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
    var onForwardKey: ((NSEvent) -> Void)?
    var onEnterFocus: (() -> Void)?
    var onExitFocus: (() -> Void)?
    var inFocusMode: Bool = false
    private var cmdSpacePeeking = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if inFocusMode {
            if event.keyCode == 53 && event.modifierFlags.contains(.command) {
                onExitFocus?(); return
            }
            onForwardKey?(event)
            return
        }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: onEscape?(); return
        case 49:
            if !event.isARepeat {
                cmdSpacePeeking = cmd
                onSpaceDown?()
            }
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
            onSpaceUp?()
            if cmdSpacePeeking {
                cmdSpacePeeking = false
                onEnterFocus?()
            }
            return
        }
        if inFocusMode { onForwardKey?(event) }
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
