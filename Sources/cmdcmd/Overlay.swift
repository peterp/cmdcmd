import AppKit
import ScreenCaptureKit

final class Overlay {
    private var window: NSWindow?
    private var view: OverlayView?
    private var visible = false
    private var allTiles: [Tile] = []
    private var tiles: [Tile] = []
    private var gridCols: Int = 1
    private var selectedIndex: Int = 0
    private var isZoomed = false
    private var savedFrames: [CGRect] = []
    private var activeSpaceAtShow: CGSSpaceID = 0
    private var prevFrontPID: pid_t = 0
    private var prevFrontTitle: String = ""
    private var showIgnored: Bool = false
    private var focusMode: Bool = false
    private var focusMonitor: Any?
    private var dragState: DragState?
    private let tracker: SpaceTracker

    private var ignoredKeys: Set<String> {
        get { Set((UserDefaults.standard.array(forKey: "ignoredWindows") as? [String]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ignoredWindows") }
    }

    private struct DragState {
        var index: Int
        var offset: CGPoint
        var startPoint: CGPoint
        var moved: Bool
    }

    private var savedOrder: [CGWindowID] {
        get {
            (UserDefaults.standard.array(forKey: "tileOrder") as? [NSNumber] ?? [])
                .map { $0.uint32Value }
        }
        set {
            UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "tileOrder")
        }
    }

    private var workspaceObserver: NSObjectProtocol?
    private var activityTimer: Timer?

    init(tracker: SpaceTracker) {
        self.tracker = tracker
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reclaimFocusIfNeeded()
        }
    }

    deinit {
        if let o = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    private func reclaimFocusIfNeeded() {
        guard visible, !focusMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.visible, !self.focusMode, !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            if let v = self.view { self.window?.makeFirstResponder(v) }
        }
    }

    func toggle() {
        if visible {
            if NSApp.isActive {
                hide()
            } else if focusMode {
                exitFocusMode()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                if let v = view { window?.makeFirstResponder(v) }
            }
        } else {
            show()
        }
    }

    private func show() {
        activeSpaceAtShow = tracker.activeSpace()
        prevFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        prevFrontTitle = focusedWindowTitle(pid: prevFrontPID) ?? ""
        visible = true
        startActivityTimer()
        Task { await prepareAndShow() }
    }

    private func startActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            for t in self.allTiles { t.updateActivity(now: now, threshold: 1.5) }
        }
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        let axWin = win as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private func prepareAndShow() async {
        let scContent: SCShareableContent?
        do {
            scContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            Log.write("SCShareableContent failed: \(error)")
            scContent = nil
        }
        let candidates = (scContent?.windows ?? []).filter(Self.isCapturable)

        await MainActor.run {
            guard visible else { return }
            let screenFrame = NSScreen.main?.visibleFrame ?? .zero
            let w = window ?? makeWindow(frame: screenFrame)
            window = w
            w.setFrame(screenFrame, display: false)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let v = view { w.makeFirstResponder(v) }
            installTiles(candidates: candidates)
        }
    }

    private func installTiles(candidates: [SCWindow]) {
        let mcTiles: [Tile] = candidates.compactMap { w -> Tile? in
            guard let pid = w.owningApplication?.processID else { return nil }
            return Tile(scWindow: w, ownerPID: pid)
        }

        let saved = savedOrder
        let ordered: [Tile]
        if saved.isEmpty {
            ordered = mcTiles
        } else {
            let presentIDs = Set(mcTiles.map { CGWindowID($0.scWindow.windowID) })
            let knownInOrder = saved.filter { presentIDs.contains($0) }
            let knownIDs = Set(knownInOrder)
            let known = knownInOrder.compactMap { wid in mcTiles.first(where: { CGWindowID($0.scWindow.windowID) == wid }) }
            let unknown = mcTiles.filter { !knownIDs.contains(CGWindowID($0.scWindow.windowID)) }
            ordered = known + unknown
        }
        savedOrder = ordered.map { CGWindowID($0.scWindow.windowID) }

        allTiles = ordered
        for t in ordered {
            window?.contentView?.layer?.addSublayer(t.layer)
        }
        rebuildDisplayed()
        if let i = tiles.firstIndex(where: { $0.ownerPID == prevFrontPID && ($0.scWindow.title ?? "") == prevFrontTitle })
            ?? tiles.firstIndex(where: { $0.ownerPID == prevFrontPID }) {
            selectedIndex = i
            updateSelection()
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for t in ordered { group.addTask { await t.start() } }
            }
        }
    }

    private func rebuildDisplayed() {
        let ignored = ignoredKeys
        let displayed = allTiles.filter { !ignored.contains($0.ignoreKey) || showIgnored }
        for t in allTiles {
            let isIgnored = ignored.contains(t.ignoreKey)
            t.layer.isHidden = isIgnored && !showIgnored
            t.layer.opacity = (isIgnored && showIgnored) ? 0.35 : 1.0
            t.setNumber(nil)
        }
        tiles = displayed
        for (i, t) in tiles.enumerated() {
            t.setNumber(i < 9 ? i + 1 : nil)
        }
        let bounds = window?.contentView?.bounds ?? .zero
        layoutTiles(in: bounds)
        if !tiles.indices.contains(selectedIndex) {
            selectedIndex = tiles.isEmpty ? 0 : 0
        }
        updateSelection()
    }

    private func toggleIgnoreSelected() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let key = tiles[selectedIndex].ignoreKey
        var set = ignoredKeys
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        ignoredKeys = set
        let prev = selectedIndex
        rebuildDisplayed()
        selectedIndex = min(prev, max(0, tiles.count - 1))
        updateSelection()
        layoutTilesAnimated()
    }

    private func forwardKey(_ event: NSEvent) {
        guard tiles.indices.contains(selectedIndex) else { return }
        let pid = tiles[selectedIndex].ownerPID
        event.cgEvent?.postToPid(pid)
    }

    private func enterFocusMode() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let tile = tiles[selectedIndex]
        focusMode = true
        view?.inFocusMode = true
        updateSelection()

        if let app = NSRunningApplication(processIdentifier: tile.ownerPID) {
            app.activate()
        }
        if let title = tile.scWindow.title, !title.isEmpty {
            raiseAXWindow(pid: tile.ownerPID, title: title)
        }

        if focusMonitor == nil {
            focusMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, event.modifierFlags.contains(.command) else { return }
                DispatchQueue.main.async { self?.exitFocusMode() }
            }
        }
    }

    private func exitFocusMode() {
        guard focusMode else { return }
        focusMode = false
        view?.inFocusMode = false
        updateSelection()
        if let m = focusMonitor {
            NSEvent.removeMonitor(m)
            focusMonitor = nil
        }
        guard visible, let w = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if let v = view { w.makeFirstResponder(v) }
    }


    private func unignoreSelected() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let key = tiles[selectedIndex].ignoreKey
        var set = ignoredKeys
        guard set.remove(key) != nil else { return }
        ignoredKeys = set
        let prev = selectedIndex
        rebuildDisplayed()
        selectedIndex = min(prev, max(0, tiles.count - 1))
        updateSelection()
        layoutTilesAnimated()
    }

    private func toggleShowIgnored() {
        showIgnored.toggle()
        rebuildDisplayed()
        layoutTilesAnimated()
    }

    private func hide() {
        let toStop = allTiles
        stopActivityTimer()
        window?.orderOut(nil)
        visible = false
        if prevFrontPID != 0,
           let app = NSRunningApplication(processIdentifier: prevFrontPID) {
            app.activate()
        }
        prevFrontPID = 0
        tiles = []
        allTiles = []
        selectedIndex = 0
        showIgnored = false
        focusMode = false
        view?.inFocusMode = false
        if let m = focusMonitor {
            NSEvent.removeMonitor(m)
            focusMonitor = nil
        }
        Task {
            for t in toStop { await t.stop() }
        }
        isZoomed = false
        savedFrames = []
        if let root = window?.contentView?.layer {
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
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
            tile.setFrame(CGRect(x: x, y: y, width: tileW, height: tileH))
        }
    }

    private func updateSelection() {
        for (i, t) in tiles.enumerated() {
            let selected = (i == selectedIndex)
            t.highlight = selected ? (focusMode ? .glow : .subtle) : .none
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
        let pid = tile.ownerPID
        let title = tile.scWindow.title
        prevFrontPID = 0
        hide()
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        if let title, !title.isEmpty {
            raiseAXWindow(pid: pid, title: title)
        }
    }

    private func raiseAXWindow(pid: pid_t, title: String) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for win in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            if let t = titleRef as? String, t == title {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                return
            }
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
            tile.setFrame(CGRect(
                x: point.x + state.offset.x,
                y: point.y + state.offset.y,
                width: f.width,
                height: f.height
            ))
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
                savedOrder = tiles.map { CGWindowID($0.scWindow.windowID) }
                selectedIndex = target
                renumberTiles()
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
        savedOrder = tiles.map { CGWindowID($0.scWindow.windowID) }
        selectedIndex = target
        renumberTiles()
        layoutTilesAnimated()
        updateSelection()
    }

    private func renumberTiles() {
        for (i, t) in tiles.enumerated() {
            t.setNumber(i < 9 ? i + 1 : nil)
        }
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
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (i, t) in tiles.enumerated() {
            if i == selectedIndex {
                t.layer.zPosition = 1
                t.setFrame(target)
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
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (i, t) in tiles.enumerated() {
            if i < savedFrames.count { t.setFrame(savedFrames[i]) }
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
        w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        w.isOpaque = false
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
        v.onIgnore = { [weak self] in self?.toggleIgnoreSelected() }
        v.onUnignore = { [weak self] in self?.unignoreSelected() }
        v.onToggleIgnoredView = { [weak self] in self?.toggleShowIgnored() }
        v.onForwardKey = { [weak self] e in self?.forwardKey(e) }
        v.onEnterFocus = { [weak self] in self?.enterFocusMode() }
        v.onExitFocus = { [weak self] in self?.exitFocusMode() }
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
    var onIgnore: (() -> Void)?
    var onUnignore: (() -> Void)?
    var onToggleIgnoredView: (() -> Void)?
    var onForwardKey: ((NSEvent) -> Void)?
    var onEnterFocus: (() -> Void)?
    var onExitFocus: (() -> Void)?
    var inFocusMode: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if inFocusMode {
            if event.keyCode == 53 && event.modifierFlags.contains(.command) {
                onExitFocus?(); return
            }
            onForwardKey?(event)
            return
        }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: onEscape?(); return
        case 49:
            if !event.isARepeat { onSpaceDown?() }
            return
        case 36, 76: onEnter?(); return
        case 3 where cmd: onEnterFocus?(); return
        case 123 where cmd: onSwap?(-1, 0); return
        case 124 where cmd: onSwap?(1, 0); return
        case 125 where cmd: onSwap?(0, 1); return
        case 126 where cmd: onSwap?(0, -1); return
        case 123: onArrow?(-1, 0); return
        case 124: onArrow?(1, 0); return
        case 125: onArrow?(0, 1); return
        case 126: onArrow?(0, -1); return
        case 27 where cmd: onIgnore?(); return
        case 24 where cmd: onUnignore?(); return
        case 34 where cmd: onToggleIgnoredView?(); return
        default: break
        }
        if !cmd, let ch = event.charactersIgnoringModifiers, ch.count == 1,
           let n = Int(ch), (1...9).contains(n) {
            onDigit?(n)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { onSpaceUp?(); return }
        if inFocusMode { onForwardKey?(event) }
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
