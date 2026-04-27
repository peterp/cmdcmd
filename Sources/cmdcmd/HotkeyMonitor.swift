import AppKit

final class HotkeyMonitor {
    private var monitors: [Any] = []
    private let target: Shortcut
    private let handler: () -> Void

    init?(spec: String, handler: @escaping () -> Void) {
        guard let s = Shortcut.parse(spec) else { return nil }
        self.target = s
        self.handler = handler

        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            _ = self?.checkAndFire(e)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if self?.checkAndFire(e) == true { return nil }
            return e
        }
        monitors = [global, local].compactMap { $0 }
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }

    @discardableResult
    private func checkAndFire(_ e: NSEvent) -> Bool {
        guard let s = Shortcut.from(event: e), s == target else { return false }
        DispatchQueue.main.async { self.handler() }
        return true
    }
}
