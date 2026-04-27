import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo


final class Tile: NSObject, SCStreamOutput, SCStreamDelegate {
    static let colorNames = ["green", "blue", "red", "yellow", "orange", "purple"]

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

    let scWindow: SCWindow?
    let windowID: CGWindowID
    let sourceFrame: CGRect
    let sourceTitle: String?
    let ownerPID: pid_t
    let ignoreKey: String
    let layer: CALayer
    private let content: CALayer
    private let numberChip: CALayer
    private let numberText: CATextLayer
    private let titlePill: CALayer
    private let titleText: CATextLayer
    private let idleDot: CALayer
    private let minimalMode: Bool
    private var lastSignificantChangeAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private(set) var isIdle: Bool = false
    private var stream: SCStream?
    private var cancelled = false
    private let queue = DispatchQueue(label: "cmdcmd.tile", qos: .userInteractive)

    init(scWindow: SCWindow, ownerPID: pid_t, minimalMode: Bool = false) {
        self.scWindow = scWindow
        self.windowID = CGWindowID(scWindow.windowID)
        self.sourceFrame = scWindow.frame
        self.sourceTitle = scWindow.title
        self.ownerPID = ownerPID
        self.minimalMode = minimalMode
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
        inner.backgroundColor = minimalMode ? NSColor.black.withAlphaComponent(0.24).cgColor : NSColor(white: 0.08, alpha: 1).cgColor
        inner.cornerRadius = minimalMode ? 14 : 9
        inner.contentsGravity = minimalMode ? .resizeAspect : .resizeAspect
        inner.minificationFilter = .trilinear
        inner.magnificationFilter = .linear
        inner.masksToBounds = true
        inner.borderColor = minimalMode ? NSColor.clear.cgColor : NSColor.white.withAlphaComponent(0.18).cgColor
        inner.borderWidth = minimalMode ? 0 : 1
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
        if minimalMode {
            installAppIcon()
        }
    }

    init(spaceWindow: SpaceWindow) {
        self.scWindow = nil
        self.windowID = spaceWindow.windowID
        self.sourceFrame = spaceWindow.bounds
        self.sourceTitle = spaceWindow.title
        self.ownerPID = spaceWindow.ownerPID
        self.minimalMode = true
        self.ignoreKey = "\(spaceWindow.ownerName)|||\(spaceWindow.title)"

        let outer = CALayer()
        outer.masksToBounds = false
        outer.shadowOpacity = 0
        outer.shadowRadius = 12
        outer.shadowOffset = .zero
        outer.cornerRadius = 10
        outer.borderColor = NSColor.clear.cgColor
        outer.borderWidth = 0
        let inner = CALayer()
        inner.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        inner.cornerRadius = 14
        inner.contentsGravity = .resizeAspect
        inner.minificationFilter = .trilinear
        inner.magnificationFilter = .linear
        inner.masksToBounds = true
        inner.borderColor = NSColor.clear.cgColor
        inner.borderWidth = 0
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
        self.windowTitle = spaceWindow.title
        super.init()
        installAppIcon()
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

    private func installAppIcon() {
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else { return }
        let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
        let size: CGFloat = 64
        icon.size = NSSize(width: size, height: size)
        content.contents = icon
        content.contentsGravity = .resizeAspect
        content.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }
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
        titleText.string = minimalMode ? "" : trimmed
        titlePill.isHidden = minimalMode || trimmed.isEmpty
        layoutLabel()
    }

    func setFrame(_ rect: CGRect) {
        layer.frame = rect
        if minimalMode {
            let iconSide = min(rect.width, rect.height) * 0.62
            content.frame = CGRect(x: (rect.width - iconSide) / 2, y: (rect.height - iconSide) / 2, width: iconSide, height: iconSide)
        } else {
            content.frame = CGRect(origin: .zero, size: rect.size).insetBy(dx: 1, dy: 1)
        }
        layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: minimalMode ? 14 : 10, cornerHeight: minimalMode ? 14 : 10, transform: nil)
        layoutLabel()
    }

    private func layoutLabel() {
        let rect = content.bounds
        guard rect.width > 0 else { return }
        let badgeHeight: CGFloat = minimalMode ? 18 : 22
        let inset: CGFloat = minimalMode ? 2 : 8
        let gap: CGFloat = minimalMode ? 4 : 6
        let hPad: CGFloat = minimalMode ? 6 : 8
        let font = NSFont.systemFont(ofSize: minimalMode ? 10 : 12, weight: .semibold)
        numberText.font = font
        numberText.fontSize = font.pointSize
        titleText.font = font
        titleText.fontSize = font.pointSize
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

        let dotSize: CGFloat = minimalMode ? 7 : 10
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
            content.borderColor = minimalMode ? NSColor.clear.cgColor : NSColor.white.withAlphaComponent(0.18).cgColor
            content.borderWidth = minimalMode ? 0 : 1
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.shadowOpacity = 0
        case .subtle:
            content.borderColor = NSColor.clear.cgColor
            content.borderWidth = 0
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.borderWidth = minimalMode ? 1.5 : 3
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = minimalMode ? 0.38 : 0.6
        }
        CATransaction.commit()
    }

    func start() async {
        if cancelled || minimalMode { return }
        guard let scWindow else { return }
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
            Log.write("tile start failed wid=\(windowID): \(error)")
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
