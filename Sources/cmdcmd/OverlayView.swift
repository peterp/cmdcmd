import AppKit

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
    }
}

final class OverlayView: NSView {
    var keymap: Keymap = Keymap()
    var onAction: ((Action) -> Void)?
    var onSpaceDown: (() -> Void)?
    var onSpaceUp: (() -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onLetter: ((String) -> Void)?
    private var momentaryPeek = false

    override var acceptsFirstResponder: Bool { true }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let bareMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 49 && bareMods.isEmpty {
            if event.isARepeat { return true }
            momentaryPeek = true
            onSpaceDown?()
            return true
        }
        if let action = keymap.action(for: event) {
            onAction?(action)
            return true
        }
        if bareMods.isEmpty,
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(scalar) {
            onLetter?(chars)
            return true
        }
        return false
    }

    @discardableResult
    func handleKeyUp(_ event: NSEvent) -> Bool {
        if event.keyCode == 49 {
            if momentaryPeek {
                momentaryPeek = false
                onSpaceUp?()
            }
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        _ = handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        _ = handleKeyUp(event)
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
