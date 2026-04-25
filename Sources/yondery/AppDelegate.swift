import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: Overlay?
    private var hotkey: Hotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = Overlay()
        self.overlay = overlay
        self.hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_Y), modifiers: cmdShift) {
            overlay.toggle()
        }
    }
}
