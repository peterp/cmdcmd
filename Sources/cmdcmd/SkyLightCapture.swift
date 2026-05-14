import CoreGraphics
import Foundation

/// Thin wrapper around the private SkyLight per-window capture entrypoint.
///
/// `CGSHWCaptureWindowList` pulls a snapshot directly from the WindowServer's
/// IOSurface backing store for a CGWindowID — the same path Mission Control
/// uses for its live previews. It needs no Screen Recording TCC grant, but is
/// private SPI: every macOS release may rename or remove the symbol. We
/// resolve via `dlsym` and let the caller fall back to ScreenCaptureKit when
/// `shared` is nil.
final class SkyLightCapture: @unchecked Sendable {
    static let shared: SkyLightCapture? = SkyLightCapture()

    private typealias MainConnectionIDFn = @convention(c) () -> UInt32
    private typealias CaptureWindowListFn = @convention(c) (
        _ cid: UInt32,
        _ windows: UnsafePointer<UInt32>,
        _ count: UInt32,
        _ options: UInt32
    ) -> Unmanaged<CFArray>?

    private let mainConnection: MainConnectionIDFn
    private let captureWindowList: CaptureWindowListFn
    private let cid: UInt32

    // Values from reverse-engineered NUIKit/CGSInternal headers. Pulled
    // together they give "give me the full window pixels without WindowServer
    // applying the corner-rounding clip mask."
    private static let kCGSCaptureNominalResolution: UInt32     = 0x0200
    private static let kCGSCaptureIgnoreGlobalClipShape: UInt32 = 0x0800

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            Log.write("SkyLightCapture: dlopen failed")
            return nil
        }
        guard let mainSym = dlsym(handle, "CGSMainConnectionID"),
              let captureSym = dlsym(handle, "CGSHWCaptureWindowList") else {
            Log.write("SkyLightCapture: required symbols missing")
            return nil
        }
        self.mainConnection = unsafeBitCast(mainSym, to: MainConnectionIDFn.self)
        self.captureWindowList = unsafeBitCast(captureSym, to: CaptureWindowListFn.self)
        self.cid = self.mainConnection()
        Log.write("SkyLightCapture: ready cid=\(self.cid)")
    }

    /// One-shot capture of a single window. Returns nil if the WindowServer
    /// produces no image (e.g. window minimized, gone, or wrong CGS state).
    func captureImage(windowID: CGWindowID) -> CGImage? {
        var wid: UInt32 = windowID
        let opts = Self.kCGSCaptureNominalResolution | Self.kCGSCaptureIgnoreGlobalClipShape
        guard let unmanaged = withUnsafePointer(to: &wid, { ptr in
            captureWindowList(cid, ptr, 1, opts)
        }) else {
            return nil
        }
        let array = unmanaged.takeRetainedValue() as NSArray
        guard array.count > 0 else { return nil }
        let first = array[0]
        guard CFGetTypeID(first as CFTypeRef) == CGImage.typeID else { return nil }
        return (first as! CGImage)
    }
}
