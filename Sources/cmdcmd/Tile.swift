import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo


final class Tile: NSObject, SCStreamOutput, SCStreamDelegate {
    let scWindow: SCWindow
    let ownerPID: pid_t
    let ignoreKey: String
    let layer: CALayer
    private let content: CALayer
    private let numberLabel: CATextLayer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "cmdcmd.tile", qos: .userInteractive)

    init(scWindow: SCWindow, ownerPID: pid_t) {
        self.scWindow = scWindow
        self.ownerPID = ownerPID
        let bid = scWindow.owningApplication?.bundleIdentifier ?? ""
        let title = scWindow.title ?? ""
        self.ignoreKey = "\(bid)|||\(title)"

        let outer = CALayer()
        outer.masksToBounds = false
        outer.shadowOpacity = 0
        let inner = CALayer()
        inner.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        inner.cornerRadius = 10
        inner.contentsGravity = .resizeAspect
        inner.minificationFilter = .trilinear
        inner.magnificationFilter = .linear
        inner.masksToBounds = true
        outer.addSublayer(inner)

        let label = CATextLayer()
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.cornerRadius = 6
        label.masksToBounds = true
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.fontSize = 12
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.string = ""
        inner.addSublayer(label)

        self.layer = outer
        self.content = inner
        self.numberLabel = label
        super.init()
    }

    func setNumber(_ n: Int?) {
        numberLabel.string = n.map { "\($0)" } ?? ""
    }

    func setFrame(_ rect: CGRect) {
        layer.frame = rect
        let local = CGRect(origin: .zero, size: rect.size)
        content.frame = local
        layer.shadowPath = CGPath(roundedRect: local, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let badge = CGSize(width: 22, height: 18)
        let inset: CGFloat = 8
        numberLabel.frame = CGRect(
            x: inset,
            y: rect.size.height - badge.height - inset,
            width: badge.width,
            height: badge.height
        )
    }

    enum Highlight {
        case none, subtle, glow
    }

    var highlight: Highlight = .none {
        didSet { applyHighlight() }
    }

    private func applyHighlight() {
        switch highlight {
        case .none:
            layer.shadowOpacity = 0
            content.borderWidth = 0
        case .subtle:
            layer.shadowOpacity = 0
            content.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            content.borderWidth = 1.5
        case .glow:
            content.borderWidth = 0
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = 0.8
            layer.shadowRadius = 22
            layer.shadowOffset = .zero
        }
    }

    func start() async {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(64, Int(scWindow.frame.width * scale))
        config.height = max(64, Int(scWindow.frame.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.scalesToFit = true
        config.queueDepth = 5
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
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [content] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("tile stream stopped: \(error)")
    }
}
