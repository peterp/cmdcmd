import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo


final class Tile: NSObject, SCStreamOutput, SCStreamDelegate {
    static let colorNames = ["green", "blue", "red", "yellow", "orange", "purple"]

    private static let cacheLock = NSLock()
    private static var frameCache: [CGWindowID: CGImage] = [:]
    private static var frameCacheOrder: [CGWindowID] = []
    private static let frameCacheLimit = 100
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let cacheQueue = DispatchQueue(label: "cmdcmd.tile.cache", qos: .utility)

    static func cachedFrame(for id: CGWindowID) -> CGImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return frameCache[id]
    }

    static func setCachedFrame(_ image: CGImage, for id: CGWindowID) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if frameCache[id] == nil {
            frameCacheOrder.append(id)
        } else {
            frameCacheOrder.removeAll { $0 == id }
            frameCacheOrder.append(id)
        }
        frameCache[id] = image
        while frameCacheOrder.count > frameCacheLimit {
            let evict = frameCacheOrder.removeFirst()
            frameCache.removeValue(forKey: evict)
        }
    }

    static func color(forName name: String) -> NSColor? {
        switch name {
        case "red": return hex(0xFF5F57)
        case "yellow": return hex(0xFEBC2E)
        case "green": return hex(0x28C840)
        case "orange": return hex(0xFF9500)
        case "blue": return hex(0x4A9DFF)
        case "purple": return hex(0xAF52DE)
        default: return nil
        }
    }

    private static func hex(_ rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    let scWindow: SCWindow
    let ownerPID: pid_t
    let ignoreKey: String
    let layer: CALayer
    private let content: CALayer
    private let numberChip: CALayer
    private let numberText: CATextLayer
    private let titlePill: CALayer
    private let titleText: CATextLayer
    private let idleDot: CALayer
    private var lastSignificantChangeAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private(set) var isIdle: Bool = false
    private var stream: SCStream?
    private var cancelled = false
    private var hasRenderedFrame = false
    private var hasRenderedLiveFrame = false
    private var lastPixelBuffer: CVPixelBuffer?
    var suppressFrames = false
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
        outer.shadowRadius = 12
        outer.shadowOffset = .zero
        outer.cornerRadius = 10
        outer.borderColor = NSColor.clear.cgColor
        outer.borderWidth = 0
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

        let chip = CALayer()
        chip.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        chip.masksToBounds = true
        chip.isHidden = true
        inner.addSublayer(chip)

        let dot = CALayer()
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        dot.cornerRadius = 5
        dot.opacity = 0
        inner.addSublayer(dot)

        let chipText = CATextLayer()
        chipText.alignmentMode = .center
        chipText.foregroundColor = NSColor.white.cgColor
        chipText.backgroundColor = NSColor.clear.cgColor
        chipText.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        chipText.fontSize = 12
        chipText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        chipText.string = ""
        chip.addSublayer(chipText)

        let pill = CALayer()
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pill.masksToBounds = true
        pill.isHidden = true
        inner.addSublayer(pill)

        let pillText = CATextLayer()
        pillText.alignmentMode = .left
        pillText.truncationMode = .end
        pillText.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        pillText.backgroundColor = NSColor.clear.cgColor
        pillText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        pillText.fontSize = 12
        pillText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        pillText.string = ""
        pill.addSublayer(pillText)

        self.layer = outer
        self.content = inner
        self.numberChip = chip
        self.numberText = chipText
        self.titlePill = pill
        self.titleText = pillText
        self.idleDot = dot
        self.windowTitle = scWindow.title ?? ""
        super.init()

        if let cached = Tile.cachedFrame(for: CGWindowID(scWindow.windowID)) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inner.contents = cached
            CATransaction.commit()
            self.hasRenderedFrame = true
        }
    }

    var tintColorName: String? {
        didSet { applyTint() }
    }

    private func applyTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let name = tintColorName, let color = Tile.color(forName: name) {
            numberChip.backgroundColor = color.cgColor
        } else {
            numberChip.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
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
        if let n = currentNumber {
            numberText.string = "\(n)"
            numberChip.isHidden = false
        } else {
            numberText.string = ""
            numberChip.isHidden = true
        }
        titleText.string = trimmed
        titlePill.isHidden = trimmed.isEmpty
        layoutLabel()
    }

    func setFrame(_ rect: CGRect) {
        layer.frame = rect
        content.frame = CGRect(origin: .zero, size: rect.size).insetBy(dx: 1, dy: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 10, cornerHeight: 10, transform: nil)
        layoutLabel()
        CATransaction.commit()
    }

    private func layoutLabel() {
        let rect = content.bounds
        guard rect.width > 0 else { return }
        let badgeHeight: CGFloat = 22
        let inset: CGFloat = 8
        let gap: CGFloat = 6
        let hPad: CGFloat = 8
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let lineHeight = ceil(font.ascender - font.descender)
        let textY = (badgeHeight - lineHeight) / 2

        let chipHidden = numberChip.isHidden
        let chipFrame = CGRect(
            x: inset,
            y: rect.size.height - badgeHeight - inset,
            width: chipHidden ? 0 : badgeHeight,
            height: badgeHeight
        )
        if !chipHidden {
            numberChip.frame = chipFrame
            numberChip.cornerRadius = badgeHeight / 2
            numberText.frame = CGRect(
                x: 0,
                y: textY,
                width: chipFrame.width,
                height: lineHeight
            )
        }

        let dotSize: CGFloat = 10
        idleDot.frame = CGRect(
            x: rect.size.width - dotSize - inset,
            y: chipFrame.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )

        let pillX = inset + (chipHidden ? 0 : chipFrame.width + gap)
        let text = (titleText.string as? String) ?? ""
        if !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let textWidth = (text as NSString).size(withAttributes: attrs).width
            let avail = max(0, rect.size.width - pillX - inset)
            let pillWidth = min(avail, ceil(textWidth) + hPad * 2)
            titlePill.frame = CGRect(
                x: pillX,
                y: chipFrame.minY,
                width: pillWidth,
                height: badgeHeight
            )
            titlePill.cornerRadius = badgeHeight / 2
            titleText.frame = CGRect(
                x: hPad,
                y: textY,
                width: max(0, pillWidth - hPad * 2),
                height: lineHeight
            )
        }

    }

    enum Highlight: Equatable {
        case none, subtle
    }

    var highlight: Highlight = .none {
        didSet { applyHighlight() }
    }

    private func applyHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch highlight {
        case .none:
            content.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            content.borderWidth = 1
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.shadowOpacity = 0
        case .subtle:
            content.borderColor = NSColor.clear.cgColor
            content.borderWidth = 0
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.borderWidth = 3
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = 0.6
        }
        CATransaction.commit()
    }

    private static let thumbMaxDim: CGFloat = 800

    private func captureConfig(maxDim: CGFloat? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var w = scWindow.frame.width * scale
        var h = scWindow.frame.height * scale
        if let m = maxDim {
            let largest = max(w, h)
            if largest > m {
                let factor = m / largest
                w *= factor
                h *= factor
            }
        }
        config.width = max(64, Int(w))
        config.height = max(64, Int(h))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        return config
    }

    func snapshot() async {
        if cancelled || hasRenderedFrame || hasRenderedLiveFrame { return }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = captureConfig(maxDim: Tile.thumbMaxDim)
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if cancelled || hasRenderedLiveFrame { return }
            Tile.setCachedFrame(image, for: CGWindowID(scWindow.windowID))
            await MainActor.run {
                guard !self.hasRenderedLiveFrame else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.content.contents = image
                CATransaction.commit()
                self.hasRenderedFrame = true
            }
        } catch {
            Log.write("tile snapshot failed wid=\(scWindow.windowID): \(error)")
        }
    }

    func start() async {
        if cancelled { return }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = captureConfig()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3

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

    private func cacheLastFrameDeferred() {
        let id = CGWindowID(self.scWindow.windowID)
        let q = self.queue
        Tile.cacheQueue.async {
            var pb: CVPixelBuffer?
            q.sync {
                pb = self.lastPixelBuffer
                self.lastPixelBuffer = nil
            }
            guard let pb else { return }
            let ci = CIImage(cvPixelBuffer: pb)
            let extent = ci.extent
            let largest = max(extent.width, extent.height)
            let factor = largest > Tile.thumbMaxDim ? Tile.thumbMaxDim / largest : 1
            let scaled = factor < 1
                ? ci.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                : ci
            if let cg = Tile.ciContext.createCGImage(scaled, from: scaled.extent) {
                Tile.setCachedFrame(cg, for: id)
            }
        }
    }

    func stop() async {
        cancelled = true
        suppressFrames = true
        cacheLastFrameDeferred()
        guard let s = stream else { return }
        self.stream = nil
        try? await s.stopCapture()
    }

    func stopSync(group: DispatchGroup) {
        cancelled = true
        suppressFrames = true
        cacheLastFrameDeferred()
        guard let s = stream else { return }
        self.stream = nil
        group.enter()
        s.stopCapture { _ in group.leave() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if cancelled { return }
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }

        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let statusRaw = (attachments?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        if statusRaw == .idle || statusRaw == .blank || statusRaw == .suspended {
            return
        }

        var significantChange = false
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
                significantChange = true
            }
        }

        guard significantChange || !hasRenderedLiveFrame else { return }

        self.lastPixelBuffer = pixelBuffer

        if suppressFrames { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.suppressFrames else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.content.contents = surface
            CATransaction.commit()
            self.hasRenderedFrame = true
            self.hasRenderedLiveFrame = true
        }
    }

    func updateActivity(now: CFAbsoluteTime) {
        let elapsed = now - lastSignificantChangeAt
        let activeWithin: CFTimeInterval = 0.5
        let idleAfter: CFTimeInterval = 2.5
        let next: Bool
        if elapsed < activeWithin {
            next = false
        } else if elapsed > idleAfter {
            next = true
        } else {
            return
        }
        guard next != isIdle else { return }
        isIdle = next
        let target: Float = next ? 1 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        idleDot.opacity = target
        CATransaction.commit()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("tile stream stopped: \(error)")
    }
}
