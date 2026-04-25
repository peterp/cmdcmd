import AppKit
import Carbon.HIToolbox

/// Fires when both the left and right Command keys are held simultaneously,
/// with no other key pressed during the chord.
final class CmdChord {
    private var monitors: [Any] = []
    private var leftDown = false
    private var rightDown = false
    private var contaminated = false
    private var fired = false
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler

        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }
        let globalKey = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.markContaminated()
        }
        let localKey = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.markContaminated()
            return e
        }
        monitors = [global, local, globalKey, localKey].compactMap { $0 }
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }

    private func markContaminated() {
        if leftDown || rightDown { contaminated = true }
    }

    private func handleFlags(_ event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Command:
            leftDown = cmd && event.modifierFlags.rawValue & 0x8 != 0
        case kVK_RightCommand:
            rightDown = cmd && event.modifierFlags.rawValue & 0x10 != 0
        default:
            return
        }

        if !leftDown && !rightDown {
            contaminated = false
            fired = false
            return
        }

        if leftDown && rightDown && !contaminated && !fired {
            fired = true
            DispatchQueue.main.async { self.handler() }
        }
    }
}
