import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    var keymap: Keymap = Keymap()
    var onAction: ((Action) -> Void)?
    var onSpaceDown: (() -> Void)?
    var onSpaceUp: (() -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    private var momentaryPeek = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let bareMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 49 && bareMods.isEmpty {
            if event.isARepeat { return }
            momentaryPeek = true
            onSpaceDown?()
            return
        }
        if let action = keymap.action(for: event) {
            onAction?(action)
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
