import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo


final class Tile: NSObject, SCStreamOutput, SCStreamDelegate {
    static let colorNames = ["green", "blue", "red", "yellow", "orange", "purple"]

    static func color(forName name: String) -> NSColor? {
        switch name {
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "red": return .systemRed
        case "yellow": return .systemYellow
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        default: return nil
        }
    }

    let scWindow: SCWindow
    let ownerPID: pid_t
    let ignoreKey: String
    let layer: CALayer
    private let content: CALayer
    private let numberLabel: CATextLayer
    private let idleDot: CALayer
    private let tintBar: CALayer
    private var lastSignificantChangeAt: CFAbsoluteTime = 0
    private var stream: SCStream?
    private var cancelled = false
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
        outer.cornerRadius = 10
        outer.borderColor = NSColor.black.withAlphaComponent(0.6).cgColor
        outer.borderWidth = 1
        let inner = CALayer()
        inner.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        inner.cornerRadius = 9
        inner.contentsGravity = .resizeAspect
        inner.minificationFilter = .trilinear
        inner.magnificationFilter = .linear
        inner.masksToBounds = true
        inner.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        inner.borderWidth = 1
        outer.addSublayer(inner)

        let dot = CALayer()
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        dot.cornerRadius = 5
        dot.opacity = 0
        inner.addSublayer(dot)

        let bar = CALayer()
        bar.isHidden = true
        bar.cornerRadius = 2
        outer.addSublayer(bar)

        let label = CATextLayer()
        label.alignmentMode = .center
        label.truncationMode = .end
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
        self.idleDot = dot
        self.tintBar = bar
        self.windowTitle = scWindow.title ?? ""
        super.init()
    }

    var tintColorName: String? {
        didSet { applyTint() }
    }

    private func applyTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let name = tintColorName, let color = Tile.color(forName: name) {
            tintBar.backgroundColor = color.withAlphaComponent(0.75).cgColor
            tintBar.isHidden = false
            idleDot.backgroundColor = color.withAlphaComponent(0.85).cgColor
        } else {
            tintBar.isHidden = true
            idleDot.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        }
        CATransaction.commit()
    }

    private let windowTitle: String
    private var currentNumber: Int?

    func setNumber(_ n: Int?) {
        currentNumber = n
        updateLabel()
    }

    private func updateLabel() {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (currentNumber, trimmed.isEmpty) {
        case (nil, true): numberLabel.string = ""
        case (nil, false): numberLabel.string = trimmed
        case (let n?, true): numberLabel.string = "\(n)"
        case (let n?, false): numberLabel.string = "\(n) — \(trimmed)"
        }
        layoutLabel()
    }

    func setFrame(_ rect: CGRect) {
        layer.frame = rect
        content.frame = CGRect(origin: .zero, size: rect.size).insetBy(dx: 1, dy: 1)
        let cb = content.bounds
        layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 10, cornerHeight: 10, transform: nil)
        layoutLabel()
        let dotSize: CGFloat = 10
        let inset: CGFloat = 8
        idleDot.frame = CGRect(
            x: cb.width - dotSize - inset,
            y: cb.height - dotSize - inset,
            width: dotSize,
            height: dotSize
        )
        let barHeight: CGFloat = 4
        let barGap: CGFloat = 4
        let barInset: CGFloat = 8
        tintBar.frame = CGRect(
            x: barInset,
            y: -barHeight - barGap,
            width: rect.size.width - barInset * 2,
            height: barHeight
        )
    }

    private func layoutLabel() {
        let rect = content.bounds
        guard rect.width > 0 else { return }
        let badgeHeight: CGFloat = 18
        let inset: CGFloat = 8
        let hPad: CGFloat = 8
        let text = (numberLabel.string as? String) ?? ""
        let maxWidth = max(22, rect.size.width - inset * 2)
        let width: CGFloat
        if text.isEmpty {
            width = 0
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberLabel.font as? NSFont ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
            let textWidth = (text as NSString).size(withAttributes: attrs).width
            width = min(maxWidth, ceil(textWidth) + hPad * 2)
        }
        numberLabel.isHidden = text.isEmpty
        numberLabel.frame = CGRect(
            x: inset,
            y: rect.size.height - badgeHeight - inset,
            width: width,
            height: badgeHeight
        )
    }

    enum Highlight {
        case none, subtle
    }

    var highlight: Highlight = .none {
        didSet { applyHighlight() }
    }

    private func applyHighlight() {
        switch highlight {
        case .none:
            content.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            content.borderWidth = 1
        case .subtle:
            content.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
            content.borderWidth = 2
        }
    }

    func start() async {
        if cancelled { return }
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
            if cancelled {
                try? await s.stopCapture()
                return
            }
            self.stream = s
        } catch {
            Log.write("tile start failed wid=\(scWindow.windowID): \(error)")
        }
    }

    func stop() async {
        cancelled = true
        guard let s = stream else { return }
        self.stream = nil
        try? await s.stopCapture()
    }

    func stopSync(group: DispatchGroup) {
        cancelled = true
        guard let s = stream else { return }
        self.stream = nil
        group.enter()
        s.stopCapture { _ in group.leave() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }

        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let statusRaw = (attachments?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        if statusRaw == .idle || statusRaw == .blank || statusRaw == .suspended {
            return
        }

        if let attachments {
            let dirtyRectsRaw = attachments[.dirtyRects] as? [[String: Any]] ?? []
            var dirtyArea: CGFloat = 0
            for d in dirtyRectsRaw {
                if let r = CGRect(dictionaryRepresentation: d as CFDictionary) {
                    dirtyArea += r.width * r.height
                }
            }
            var totalArea: CGFloat = 0
            if let crDict = attachments[.contentRect] as? [String: Any],
               let cr = CGRect(dictionaryRepresentation: crDict as CFDictionary) {
                totalArea = cr.width * cr.height
            }
            if totalArea > 0, dirtyArea / totalArea > 0.005 {
                lastSignificantChangeAt = CFAbsoluteTimeGetCurrent()
            }
        }

        DispatchQueue.main.async { [content] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.contents = surface
            CATransaction.commit()
        }
    }

    func updateActivity(now: CFAbsoluteTime, threshold: CFTimeInterval) {
        let elapsed = now - lastSignificantChangeAt
        let isIdle = elapsed > threshold
        let target: Float = isIdle ? 1 : 0
        guard idleDot.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        idleDot.opacity = target
        CATransaction.commit()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("tile stream stopped: \(error)")
    }
}
