import AppKit
import CoreGraphics

final class Tile: NSObject {
    static let colorNames = ["green", "blue", "red", "yellow", "orange", "purple"]

    private static let cacheLock = NSLock()
    private static var frameCache: [CGWindowID: CGImage] = [:]
    private static var frameCacheOrder: [CGWindowID] = []
    private static let frameCacheLimit = 100
    private static let captureQueue = DispatchQueue(label: "cmdcmd.tile.capture", qos: .userInteractive, attributes: .concurrent)
    private static let pollInterval: TimeInterval = 1.0 / 15.0

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

    var window: WindowInfo
    let ownerPID: pid_t
    let layer: CALayer
    private let content: CALayer
    private let numberChip: CALayer
    private let numberText: CATextLayer
    private let titlePill: CALayer
    private let titleText: CATextLayer
    private let idleDot: CALayer
    private var lastSignificantChangeAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private(set) var isIdle: Bool = false
    private var pollTimer: DispatchSourceTimer?
    private var cancelled = false
    private var hasRenderedFrame = false
    private var hasRenderedLiveFrame = false
    var suppressFrames = false
    private var loggedFirstLiveFrame = false

    init(window: WindowInfo, ownerPID: pid_t) {
        self.window = window
        self.ownerPID = ownerPID

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
        // kCGWindowName needs Screen Recording on macOS 12.3+, which we no
        // longer ask for. Fall back to the owning-app name so the pill still
        // labels each tile.
        let rawTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowTitle = rawTitle.isEmpty ? window.applicationName : rawTitle
        super.init()

        if let cached = Tile.cachedFrame(for: window.windowID) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inner.contents = cached
            CATransaction.commit()
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
    private var currentLabel: String?
    private var currentMatchCount: Int = 0

    func setLabel(_ s: String?, matchPrefix: Int = 0) {
        currentLabel = s
        currentMatchCount = max(0, min(matchPrefix, s?.count ?? 0))
        updateLabel()
    }

    private func updateLabel() {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label = currentLabel, !label.isEmpty {
            numberText.string = Self.attributedLabel(label, matched: currentMatchCount)
            numberChip.isHidden = false
        } else {
            numberText.string = ""
            numberChip.isHidden = true
        }
        titleText.string = trimmed
        titlePill.isHidden = trimmed.isEmpty
        layoutLabel()
    }

    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    private static let labelMatchedColor = NSColor.systemYellow
    private static let labelUnmatchedColor = NSColor.white

    private static func attributedLabel(_ text: String, matched: Int) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        attr.addAttribute(.font, value: labelFont, range: full)
        attr.addAttribute(.foregroundColor, value: labelUnmatchedColor, range: full)
        if matched > 0 {
            let clamped = min(matched, text.count)
            let matchedRange = NSRange(location: 0, length: clamped)
            attr.addAttribute(.foregroundColor, value: labelMatchedColor, range: matchedRange)
        }
        return attr
    }

    func setFrame(_ rect: CGRect) {
        let newBounds = CGRect(origin: .zero, size: rect.size)
        let newShadowPath = CGPath(roundedRect: newBounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let oldShadowPath = layer.shadowPath
        let duration = CATransaction.animationDuration()
        let actionsDisabled = CATransaction.disableActions()

        layer.frame = rect
        content.frame = newBounds.insetBy(dx: 1, dy: 1)

        // CALayer does not return a default action for shadowPath, so an
        // implicit animation never starts. Without this, the path snaps to
        // the new (often much larger) size at t=0 while layer.frame is still
        // animating, which paints a phantom shadow far outside the small
        // starting tile.
        if !actionsDisabled, duration > 0, let oldShadowPath {
            let anim = CABasicAnimation(keyPath: "shadowPath")
            anim.fromValue = oldShadowPath
            anim.toValue = newShadowPath
            anim.duration = duration
            anim.timingFunction = CATransaction.animationTimingFunction()
            layer.add(anim, forKey: "shadowPath")
        }
        layer.shadowPath = newShadowPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        let chipText = (currentLabel ?? "")
        let chipWidth: CGFloat
        if chipHidden || chipText.isEmpty {
            chipWidth = 0
        } else if chipText.count <= 1 {
            chipWidth = badgeHeight
        } else {
            let measured = (chipText as NSString).size(withAttributes: [.font: Self.labelFont]).width
            chipWidth = max(badgeHeight, ceil(measured) + hPad * 2)
        }
        let chipFrame = CGRect(
            x: inset,
            y: rect.size.height - badgeHeight - inset,
            width: chipWidth,
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

    /// Single-shot SkyLight capture used to seed the tile before the live
    /// poll has a frame. Cheap to call: returns nil and lets the cached
    /// thumbnail keep showing if SkyLight has nothing for this window yet.
    func snapshot() async {
        if cancelled || hasRenderedLiveFrame { return }
        guard let sl = SkyLightCapture.shared else { return }
        let wid = window.windowID
        let image: CGImage? = await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            Tile.captureQueue.async { cont.resume(returning: sl.captureImage(windowID: wid)) }
        }
        guard let image else { return }
        if cancelled || hasRenderedLiveFrame { return }
        Tile.setCachedFrame(image, for: wid)
        await MainActor.run {
            guard !self.hasRenderedLiveFrame else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.content.contents = image
            CATransaction.commit()
            self.hasRenderedFrame = true
            self.lastSignificantChangeAt = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Start a 15 fps SkyLight poll. No-op if SkyLight is unavailable on this
    /// macOS — tiles then just keep their cached thumbnail.
    func start() async {
        if cancelled { return }
        guard let sl = SkyLightCapture.shared else { return }
        await MainActor.run { self.startPolling(sl: sl) }
    }

    private func startPolling(sl: SkyLightCapture) {
        stopPolling()
        let wid = window.windowID
        let t = DispatchSource.makeTimerSource(queue: Tile.captureQueue)
        t.schedule(deadline: .now(), repeating: Tile.pollInterval, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in
            guard let self, !self.cancelled, !self.suppressFrames else { return }
            guard let image = sl.captureImage(windowID: wid) else { return }
            Tile.setCachedFrame(image, for: wid)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled, !self.suppressFrames else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.content.contents = image
                CATransaction.commit()
                self.hasRenderedFrame = true
                self.hasRenderedLiveFrame = true
                self.lastSignificantChangeAt = CFAbsoluteTimeGetCurrent()
                if !self.loggedFirstLiveFrame {
                    self.loggedFirstLiveFrame = true
                    Log.write("tile first live frame wid=\(wid) size=\(image.width)x\(image.height)")
                }
            }
        }
        t.resume()
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    func stop() async {
        cancelled = true
        suppressFrames = true
        stopPolling()
    }

    func stopSync(group: DispatchGroup) {
        cancelled = true
        suppressFrames = true
        stopPolling()
    }

    /// Underlying window resized after capture started. The polled SkyLight
    /// path reads the current backing store on every tick, so we just need to
    /// reset the "first frame" gates and let the next poll repaint.
    func refreshAfterResize(live: Bool) async {
        if cancelled { return }
        hasRenderedLiveFrame = false
        loggedFirstLiveFrame = false
        await snapshot()
        if live && !cancelled, pollTimer == nil {
            await start()
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
}
