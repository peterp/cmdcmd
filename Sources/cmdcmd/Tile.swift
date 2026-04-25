import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

final class Tile: NSObject, SCStreamOutput, SCStreamDelegate {
    let scWindow: SCWindow
    let ownerPID: pid_t
    let layer: CALayer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "cmdcmd.tile", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(scWindow: SCWindow, ownerPID: pid_t) {
        self.scWindow = scWindow
        self.ownerPID = ownerPID
        let l = CALayer()
        l.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        l.cornerRadius = 10
        l.borderColor = NSColor.controlAccentColor.cgColor
        l.borderWidth = 0
        l.contentsGravity = .resizeAspect
        l.masksToBounds = true
        self.layer = l
        super.init()
    }

    var isSelected: Bool = false {
        didSet { layer.borderWidth = isSelected ? 4 : 0 }
    }

    func start() async {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(64, Int(scWindow.frame.width * scale / 2))
        config.height = max(64, Int(scWindow.frame.height * scale / 2))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.scalesToFit = true
        config.queueDepth = 3
        config.ignoreShadowsSingleWindow = true

        do {
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            self.stream = s
        } catch {
            Log.write("tile start failed wid=\(scWindow.windowID): \(error)")
        }
    }

    func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { [layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = cg
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("tile stream stopped: \(error)")
    }
}
