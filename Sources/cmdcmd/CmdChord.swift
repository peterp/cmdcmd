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
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
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
        installEventTap()
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventTapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes) }
    }

    private func markContaminated() {
        if leftDown || rightDown { contaminated = true }
    }

    private func installEventTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let chord = Unmanaged<CmdChord>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                if type == .keyDown {
                    chord.markContaminated()
                } else if type == .flagsChanged {
                    chord.handleFlags(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: ref) else {
            Log.write("cmd-cmd event tap unavailable")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleFlags(_ event: NSEvent) {
        handleFlags(keyCode: Int(event.keyCode), flags: event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
    }

    private func handleFlags(keyCode: Int, flags: CGEventFlags) {
        let raw = flags.rawValue
        switch keyCode {
        case kVK_Command:
            leftDown = raw & CGEventFlags.maskCommand.rawValue != 0 && raw & 0x8 != 0
        case kVK_RightCommand:
            rightDown = raw & CGEventFlags.maskCommand.rawValue != 0 && raw & 0x10 != 0
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
