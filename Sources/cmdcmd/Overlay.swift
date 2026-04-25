import AppKit
import ScreenCaptureKit

final class Overlay {
    private var window: NSWindow?
    private var view: OverlayView?
    private var visible = false
    private var tiles: [Tile] = []
    private var gridCols: Int = 1
    private var selectedIndex: Int = 0
    private var isZoomed = false
    private var savedFrames: [CGRect] = []
    private var activeSpaceAtShow: CGSSpaceID = 0
    private var joinedWindowIDs: [CGWindowID] = []
    private var joinedSpaceID: CGSSpaceID = 0
    private var dragState: DragState?
    private let tracker: SpaceTracker

    private struct DragState {
        var index: Int
        var offset: CGPoint
        var startPoint: CGPoint
        var moved: Bool
    }

    private var savedOrder: [CGSSpaceID] {
        get {
            (UserDefaults.standard.array(forKey: "tileOrder") as? [NSNumber] ?? [])
                .map { $0.uint64Value }
        }
        set {
            UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "tileOrder")
        }
    }

    init(tracker: SpaceTracker) {
        self.tracker = tracker
    }

    func toggle() {
        visible ? hide() : show()
    }

    private func show() {
        activeSpaceAtShow = tracker.activeSpace()
        let screenFrame = NSScreen.main?.frame ?? .zero
        let w = window ?? makeWindow(frame: screenFrame)
        window = w
        w.setFrame(screenFrame, display: false)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let v = view { w.makeFirstResponder(v) }
        visible = true
        Task { await loadTiles() }
    }

    private func hide() {
        window?.orderOut(nil)
        visible = false
        let toStop = tiles
        tiles = []
        selectedIndex = 0
        isZoomed = false
        savedFrames = []
        if !joinedWindowIDs.isEmpty {
            tracker.removeWindows(joinedWindowIDs, fromSpace: joinedSpaceID)
            joinedWindowIDs = []
            joinedSpaceID = 0
        }
        Task {
            for t in toStop { await t.stop() }
        }
        if let root = window?.contentView?.layer {
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
    }

    private func loadTiles() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false
            )
        } catch {
            print("SCShareableContent failed: \(error)")
            await MainActor.run { hide() }
            return
        }

        let fullscreenMap = tracker.fullscreenWindowSpaces()
        print("SCK: \(content.windows.count) total windows; \(fullscreenMap.count) in fullscreen spaces")
        let candidates = content.windows.filter { w in
            fullscreenMap[w.windowID] != nil && Self.isCapturable(w)
        }
        print("SCK: \(candidates.count) candidates after filtering")
        for w in candidates {
            print("  candidate: \(w.owningApplication?.applicationName ?? "?") title='\(w.title ?? "")' frame=\(w.frame)")
        }
        fflush(stdout)
        let order = tracker.orderedSpaceIDs()
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = candidates.sorted { a, b in
            let ra = fullscreenMap[a.windowID].flatMap { rank[$0] } ?? Int.max
            let rb = fullscreenMap[b.windowID].flatMap { rank[$0] } ?? Int.max
            return ra < rb
        }
        let mcTiles = sorted.compactMap { w -> Tile? in
            guard let sid = fullscreenMap[w.windowID] else { return nil }
            return Tile(window: w, spaceID: sid)
        }
        let saved = savedOrder
        let new: [Tile]
        if saved.isEmpty {
            new = mcTiles
        } else {
            let knownIDs = Set(saved)
            let known = saved.compactMap { sid in mcTiles.first(where: { $0.spaceID == sid }) }
            let unknown = mcTiles.filter { !knownIDs.contains($0.spaceID) }
            new = known + unknown
        }
        savedOrder = new.map { $0.spaceID }

        let inactiveIDs = new.compactMap { $0.spaceID != activeSpaceAtShow ? CGWindowID($0.window.windowID) : nil }
        if !inactiveIDs.isEmpty {
            tracker.addWindows(inactiveIDs, toSpace: activeSpaceAtShow)
            joinedWindowIDs = inactiveIDs
            joinedSpaceID = activeSpaceAtShow
            Log.write("joined \(inactiveIDs.count) windows to space \(activeSpaceAtShow)")
        }

        await MainActor.run {
            tiles = new
            let bounds = window?.contentView?.bounds ?? .zero
            Log.write("overlay bounds: \(bounds)")
            layoutTiles(in: bounds)
            for t in new {
                window?.contentView?.layer?.addSublayer(t.layer)
            }
            selectedIndex = new.firstIndex(where: { $0.spaceID == activeSpaceAtShow }) ?? 0
            updateSelection()
        }
        await withTaskGroup(of: Void.self) { group in
            for t in new { group.addTask { await t.start() } }
        }
    }

    private func pickIndex(_ n: Int) {
        guard tiles.indices.contains(n) else { return }
        selectedIndex = n
        updateSelection()
        pick()
    }

    private func layoutTiles(in bounds: NSRect) {
        let count = tiles.count
        guard count > 0 else { return }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        gridCols = cols
        let pad: CGFloat = 24

        let screenSize = NSScreen.main?.frame.size ?? bounds.size
        let ar = screenSize.width / max(1, screenSize.height)

        let availW = (bounds.width - pad * CGFloat(cols + 1)) / CGFloat(cols)
        let availH = (bounds.height - pad * CGFloat(rows + 1)) / CGFloat(rows)
        let tileW: CGFloat
        let tileH: CGFloat
        if availW / availH > ar {
            tileH = availH
            tileW = tileH * ar
        } else {
            tileW = availW
            tileH = tileW / ar
        }

        let totalW = tileW * CGFloat(cols) + pad * CGFloat(cols - 1)
        let totalH = tileH * CGFloat(rows) + pad * CGFloat(rows - 1)
        let originX = (bounds.width - totalW) / 2
        let originY = (bounds.height - totalH) / 2

        for (i, tile) in tiles.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = originX + CGFloat(col) * (tileW + pad)
            let y = bounds.height - originY - CGFloat(row + 1) * tileH - CGFloat(row) * pad
            tile.layer.frame = CGRect(x: x, y: y, width: tileW, height: tileH)
        }
    }

    private func updateSelection() {
        for (i, t) in tiles.enumerated() {
            t.isSelected = (i == selectedIndex)
        }
    }

    private func move(dx: Int, dy: Int) {
        guard !tiles.isEmpty, !isZoomed else { return }
        let cols = max(1, gridCols)
        let row = selectedIndex / cols
        let col = selectedIndex % cols
        let newCol = max(0, min(cols - 1, col + dx))
        let newRow = max(0, row + dy)
        let candidate = newRow * cols + newCol
        if candidate >= 0 && candidate < tiles.count {
            selectedIndex = candidate
        } else if dy > 0 {
            selectedIndex = tiles.count - 1
        }
        updateSelection()
    }

    private func pick() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let tile = tiles[selectedIndex]
        let sid = tile.spaceID
        let pid = tile.window.owningApplication?.processID
        hide()
        tracker.switchTo(spaceID: sid)
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    private func mouseDownAt(_ point: NSPoint) {
        guard let i = tiles.firstIndex(where: { $0.layer.frame.contains(point) }) else {
            dragState = nil
            return
        }
        let tile = tiles[i]
        dragState = DragState(
            index: i,
            offset: CGPoint(x: tile.layer.frame.origin.x - point.x,
                            y: tile.layer.frame.origin.y - point.y),
            startPoint: point,
            moved: false
        )
        tile.layer.zPosition = 1
        selectedIndex = i
        updateSelection()
    }

    private func mouseDraggedAt(_ point: NSPoint) {
        guard var state = dragState, tiles.indices.contains(state.index) else { return }
        if !state.moved {
            let dist = hypot(point.x - state.startPoint.x, point.y - state.startPoint.y)
            if dist > 5 { state.moved = true }
        }
        if state.moved {
            let tile = tiles[state.index]
            let f = tile.layer.frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tile.layer.frame = CGRect(
                x: point.x + state.offset.x,
                y: point.y + state.offset.y,
                width: f.width,
                height: f.height
            )
            CATransaction.commit()
        }
        dragState = state
    }

    private func mouseUpAt(_ point: NSPoint) {
        guard let state = dragState, tiles.indices.contains(state.index) else {
            dragState = nil
            return
        }
        let tile = tiles[state.index]
        tile.layer.zPosition = 0
        if state.moved {
            if let target = tiles.firstIndex(where: { $0 !== tile && $0.layer.frame.contains(point) }) {
                tiles.swapAt(state.index, target)
                savedOrder = tiles.map { $0.spaceID }
                selectedIndex = target
            }
            layoutTilesAnimated()
            updateSelection()
        } else {
            pick()
        }
        dragState = nil
    }

    private func swapSelected(dx: Int, dy: Int) {
        guard !tiles.isEmpty, !isZoomed else { return }
        let cols = max(1, gridCols)
        let row = selectedIndex / cols
        let col = selectedIndex % cols
        let newCol = col + dx
        let newRow = row + dy
        let target = newRow * cols + newCol
        guard newCol >= 0, newCol < cols, newRow >= 0, target >= 0, target < tiles.count else { return }
        tiles.swapAt(selectedIndex, target)
        savedOrder = tiles.map { $0.spaceID }
        selectedIndex = target
        layoutTilesAnimated()
        updateSelection()
    }

    private func layoutTilesAnimated() {
        let bounds = window?.contentView?.bounds ?? .zero
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        layoutTiles(in: bounds)
        CATransaction.commit()
    }

    private func beginZoom() {
        guard !isZoomed, tiles.indices.contains(selectedIndex) else { return }
        let bounds = window?.contentView?.bounds ?? .zero
        let pad: CGFloat = 16
        let target = bounds.insetBy(dx: pad, dy: pad)
        savedFrames = tiles.map { $0.layer.frame }
        isZoomed = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        for (i, t) in tiles.enumerated() {
            if i == selectedIndex {
                t.layer.zPosition = 1
                t.layer.frame = target
            } else {
                t.layer.opacity = 0
            }
        }
        CATransaction.commit()
    }

    private func endZoom() {
        guard isZoomed else { return }
        isZoomed = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        for (i, t) in tiles.enumerated() {
            if i < savedFrames.count { t.layer.frame = savedFrames[i] }
            t.layer.zPosition = 0
            t.layer.opacity = 1
        }
        CATransaction.commit()
        savedFrames = []
    }

    private static let systemOwners: Set<String> = [
        "Window Server", "Dock", "WindowManager", "Control Center",
        "Spotlight", "NotificationCenter", "SystemUIServer",
        "TextInputMenuAgent", "Wallpaper",
    ]

    private static func isCapturable(_ w: SCWindow) -> Bool {
        guard let app = w.owningApplication else { return false }
        if app.processID == getpid() { return false }
        if systemOwners.contains(app.applicationName) { return false }
        if w.frame.width < 200 || w.frame.height < 200 { return false }
        if !w.isOnScreen && w.windowLayer != 0 { return false }
        return true
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let w = OverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .popUpMenu
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = OverlayView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        v.onEscape = { [weak self] in self?.hide() }
        v.onArrow = { [weak self] dx, dy in self?.move(dx: dx, dy: dy) }
        v.onEnter = { [weak self] in self?.pick() }
        v.onSpaceDown = { [weak self] in self?.beginZoom() }
        v.onSpaceUp = { [weak self] in self?.endZoom() }
        v.onMouseDown = { [weak self] p in self?.mouseDownAt(p) }
        v.onMouseDragged = { [weak self] p in self?.mouseDraggedAt(p) }
        v.onMouseUp = { [weak self] p in self?.mouseUpAt(p) }
        v.onDigit = { [weak self] n in self?.pickIndex(n - 1) }
        v.onSwap = { [weak self] dx, dy in self?.swapSelected(dx: dx, dy: dy) }
        w.contentView = v
        view = v
        return w
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    var onEscape: (() -> Void)?
    var onArrow: ((Int, Int) -> Void)?
    var onEnter: (() -> Void)?
    var onSpaceDown: (() -> Void)?
    var onSpaceUp: (() -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onDigit: ((Int) -> Void)?
    var onSwap: ((Int, Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: onEscape?()
        case 36, 76: onEnter?()
        case 49:
            if !event.isARepeat { onSpaceDown?() }
        case 123: cmd ? onSwap?(-1, 0) : onArrow?(-1, 0)
        case 124: cmd ? onSwap?(1, 0) : onArrow?(1, 0)
        case 125: cmd ? onSwap?(0, 1) : onArrow?(0, 1)
        case 126: cmd ? onSwap?(0, -1) : onArrow?(0, -1)
        default:
            if let ch = event.charactersIgnoringModifiers,
               ch.count == 1,
               let n = Int(ch),
               (1...9).contains(n) {
                onDigit?(n)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { onSpaceUp?() } else { super.keyUp(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }
}
