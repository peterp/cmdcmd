import AppKit
import CoreGraphics

/// Plain snapshot of the per-window facts we used to lean on `SCWindow` for.
/// Populated from `CGWindowListCopyWindowInfo` + `NSRunningApplication` so the
/// app never needs to spin up ScreenCaptureKit just to enumerate windows
/// (which would light the screen-recording indicator).
struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
    let applicationName: String
    let bundleIdentifier: String?
    let processID: pid_t
    let layer: Int
    let isOnScreen: Bool

    /// All currently on-screen windows, in WindowServer Z-order (front-most first).
    static func enumerate() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var bundleCache: [pid_t: String?] = [:]
        return raw.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pidNum = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let pid = pid_t(pidNum)
            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            let title = entry[kCGWindowName as String] as? String
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let bundleID: String?
            if let cached = bundleCache[pid] {
                bundleID = cached
            } else {
                let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleCache[pid] = resolved
                bundleID = resolved
            }
            return WindowInfo(
                windowID: CGWindowID(id),
                frame: frame,
                title: title,
                applicationName: owner,
                bundleIdentifier: bundleID,
                processID: pid,
                layer: layer,
                isOnScreen: onScreen
            )
        }
    }
}
