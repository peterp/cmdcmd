import AppKit
import ApplicationServices

final class SwipeMonitor {
    private var monitor: Any?

    init(onSwipeUp: @escaping () -> Void) {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted {
            print("cmd & cmd needs Accessibility permission for trackpad swipes.")
            print("Grant it in: System Settings → Privacy & Security → Accessibility")
        }

        self.monitor = NSEvent.addGlobalMonitorForEvents(matching: .swipe) { event in
            if event.deltaY > 0 {
                onSwipeUp()
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
