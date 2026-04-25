import AppKit

final class Overlay {
    private var window: NSWindow?
    private var visible = false

    func toggle() {
        visible ? hide() : show()
    }

    private func show() {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let w = window ?? makeWindow(frame: screenFrame)
        window = w
        w.setFrame(screenFrame, display: false)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        visible = true
    }

    private func hide() {
        window?.orderOut(nil)
        visible = false
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = OverlayView(frame: frame)
        return w
    }
}

private final class OverlayView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.orderOut(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
