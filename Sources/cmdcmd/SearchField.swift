import AppKit

/// Bottom-center search field shown when the user enters search mode.
/// Contains an editable text field plus a Cancel button. The text field
/// receives all keystrokes while visible; the host wires up callbacks for
/// query changes, return (commit), and esc/cancel.
final class SearchField {
    private var container: NSView?
    private var field: SearchTextField?
    private var cancelButton: NSButton?
    private weak var hostWindow: NSWindow?

    enum ArrowDirection { case left, right, up, down }

    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onArrow: ((ArrowDirection) -> Void)?

    var isVisible: Bool { container?.superview != nil && !(container?.isHidden ?? true) }

    var query: String { field?.stringValue ?? "" }

    func show(in host: NSView, query: String) {
        hostWindow = host.window
        let view = container ?? makeContainer()
        if container == nil {
            container = view
            host.addSubview(view)
        } else if view.superview !== host {
            view.removeFromSuperview()
            host.addSubview(view)
        }
        view.isHidden = false
        field?.stringValue = query
        layout(in: host.bounds)
        if let f = field {
            host.window?.makeFirstResponder(f)
            // Place cursor at end after string assignment.
            f.currentEditor()?.selectedRange = NSRange(location: query.count, length: 0)
        }
    }

    func hide() {
        container?.isHidden = true
        if let host = container?.superview, let win = host.window {
            // Return first responder to the OverlayView so keymap routing resumes.
            win.makeFirstResponder(host)
        }
    }

    func reset() {
        container?.removeFromSuperview()
        container = nil
        field = nil
        cancelButton = nil
    }

    func relayout(in bounds: CGRect) {
        guard isVisible else { return }
        layout(in: bounds)
    }

    private func layout(in bounds: CGRect) {
        guard let view = container else { return }
        let width: CGFloat = 360
        let height: CGFloat = 36
        view.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: 24,
            width: width,
            height: height
        )
        let buttonWidth: CGFloat = 70
        let pad: CGFloat = 8
        field?.frame = CGRect(x: pad, y: 6, width: width - buttonWidth - pad * 3, height: height - 12)
        cancelButton?.frame = CGRect(
            x: width - buttonWidth - pad,
            y: 4,
            width: buttonWidth,
            height: height - 8
        )
    }

    private func makeContainer() -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        let layer = v.layer!
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer.cornerRadius = 12
        layer.masksToBounds = true

        let f = SearchTextField()
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(
            string: "Search apps & windows…",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            ]
        )
        f.target = self
        f.action = #selector(commit)
        f.delegate = TextDelegate.shared
        TextDelegate.shared.host = self
        v.addSubview(f)
        field = f

        let btn = NSButton(title: "Done", target: self, action: #selector(cancel))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        v.addSubview(btn)
        cancelButton = btn

        return v
    }

    @objc private func commit() {
        onCommit?()
    }

    @objc private func cancel() {
        onCancel?()
    }

    fileprivate func didChangeText() {
        onChange?(query)
    }

    fileprivate func didPressEscape() {
        onCancel?()
    }

    fileprivate func didPressArrow(_ d: ArrowDirection) {
        onArrow?(d)
    }

    private final class TextDelegate: NSObject, NSTextFieldDelegate {
        static let shared = TextDelegate()
        weak var host: SearchField?

        func controlTextDidChange(_ obj: Notification) {
            host?.didChangeText()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                host?.didPressEscape()
                return true
            }
            // Swallow all caret-movement selectors so the cursor never moves
            // inside the field. Forward the cardinal arrows to tile selection.
            if let dir = Self.arrowDirection(for: selector) {
                host?.didPressArrow(dir)
                return true
            }
            if Self.movementSelectors.contains(selector) {
                return true
            }
            return false
        }

        private static func arrowDirection(for selector: Selector) -> ArrowDirection? {
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):  return .left
            case #selector(NSResponder.moveRight(_:)): return .right
            case #selector(NSResponder.moveUp(_:)):    return .up
            case #selector(NSResponder.moveDown(_:)):  return .down
            default: return nil
            }
        }

        private static let movementSelectors: Set<Selector> = [
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:)),
            #selector(NSResponder.moveWordLeft(_:)),
            #selector(NSResponder.moveWordRight(_:)),
            #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
            #selector(NSResponder.moveWordRightAndModifySelection(_:)),
            #selector(NSResponder.moveToBeginningOfLine(_:)),
            #selector(NSResponder.moveToEndOfLine(_:)),
            #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
            #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
            #selector(NSResponder.moveToBeginningOfDocument(_:)),
            #selector(NSResponder.moveToEndOfDocument(_:)),
            #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)),
            #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)),
            #selector(NSResponder.moveToLeftEndOfLine(_:)),
            #selector(NSResponder.moveToRightEndOfLine(_:)),
        ]
    }
}

/// NSTextField subclass that intercepts cmd+f so the host can re-trigger
/// search mode (toggle/refocus) without inserting an "f" character.
final class SearchTextField: NSTextField {
    var onCmdF: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command],
           (event.charactersIgnoringModifiers ?? "").lowercased() == "f" {
            onCmdF?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
