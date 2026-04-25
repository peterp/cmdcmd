import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

final class Tile: NSObject, SCStreamOutput, SCStreamDelegate {
    let window: SCWindow
    let spaceID: CGSSpaceID
    let layer: CALayer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "cmdcmd.tile", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(window: SCWindow, spaceID: CGSSpaceID) {
        self.window = window
        self.spaceID = spaceID
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer.cornerRadius = 8
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.masksToBounds = true
        self.layer = layer
        super.init()
    }

    var isSelected: Bool = false {
        didSet { layer.borderWidth = isSelected ? 4 : 0 }
    }

    func start() async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(64, Int(window.frame.width * scale / 2))
        config.height = max(64, Int(window.frame.height * scale / 2))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.scalesToFit = true
        config.queueDepth = 3
        config.ignoreShadowsSingleWindow = true

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            Log.write("tile start failed for \(window.owningApplication?.applicationName ?? "?"): \(error)")
        }
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { [layer] in
            layer.contents = cg
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("tile stream stopped: \(error)")
    }
}
