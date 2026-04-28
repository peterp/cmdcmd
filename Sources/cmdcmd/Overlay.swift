import AppKit
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ axEl: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

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
    private var prevFrontPID: pid_t = 0
    private var prevFrontTitle: String = ""
    private var prevPickedWindowID: CGWindowID?
    private var showIgnored: Bool = false
    private var dragState: DragState?
    private var lastLetterJump: String?
    private let tracker: SpaceTracker
    private var config: Config

    func updateConfig(_ config: Config) {
        self.config = config
    }

    private var displayKey: String = "main"
    private var activeScreen: NSScreen?

    private var ignoredKeys: Set<String> {
        get { Set((UserDefaults.standard.array(forKey: "ignoredWindows.\(displayKey)") as? [String]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ignoredWindows.\(displayKey)") }
    }

    private var paneColors: [CGWindowID: String] = [:]

    private struct DragState {
        var index: Int
        var offset: CGPoint
        var startPoint: CGPoint
        var moved: Bool
    }

    private var savedOrder: [CGWindowID] {
        get {
            (UserDefaults.standard.array(forKey: "tileOrder.\(displayKey)") as? [NSNumber] ?? [])
                .map { $0.uint32Value }
        }
        set {
            UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "tileOrder.\(displayKey)")
        }
    }

    private var workspaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var activityTimer: Timer?
    private let hint = HintPill()

    private var cachedShareable: SCShareableContent?
    private var cachedShareableAt: CFAbsoluteTime = 0

    private static var usageOrder: [String] {
        get { (UserDefaults.standard.array(forKey: "appUsageOrder") as? [String]) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(128)), forKey: "appUsageOrder") }
    }

    private static func usageKey(pid: pid_t, bundleIdentifier: String?) -> String {
        if let id = bundleIdentifier, !id.isEmpty { return id }
        return "pid:\(pid)"
    }

    private static func usageKey(for tile: Tile) -> String {
        usageKey(pid: tile.ownerPID, bundleIdentifier: tile.scWindow.owningApplication?.bundleIdentifier)
    }

    private static func recordUse(of app: NSRunningApplication) {
        guard app.processIdentifier != getpid(), app.activationPolicy == .regular else { return }
        let key = usageKey(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        var order = usageOrder.filter { $0 != key }
        order.insert(key, at: 0)
        usageOrder = order
    }

    init(tracker: SpaceTracker, config: Config) {
        self.tracker = tracker
        self.config = config
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.visible, !self.isPicking else { return }
            self.hide(activatePrevious: false)
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Self.recordUse(of: app)
        }
        prewarmShareable()
    }

    private func prewarmShareable() {
        Task { [weak self] in
            do {
                let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                await MainActor.run {
                    guard let self else { return }
                    self.cachedShareable = c
                    self.cachedShareableAt = CFAbsoluteTimeGetCurrent()
                }
            } catch {
                Log.write("SCShareableContent prewarm failed: \(error)")
            }
        }
    }

    private var isPicking = false

    deinit {
        if let o = workspaceObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    func toggle() {
        if visible {
            if NSApp.isActive {
                dismiss()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                if let v = view { window?.makeFirstResponder(v) }
            }
        } else {
            show()
        }
    }

    private func dismiss() {
        guard visible, !isPicking else { return }
        if tiles.indices.contains(selectedIndex) {
            pick()
        } else {
            hide()
        }
    }

    private func show() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let prevApp = NSWorkspace.shared.frontmostApplication
        prevFrontPID = prevApp?.processIdentifier ?? 0
        if let prevApp { Self.recordUse(of: prevApp) }
        prevFrontTitle = focusedWindowTitle(pid: prevFrontPID) ?? ""
        let screen = Self.cursorScreen()
        activeScreen = screen
        displayKey = Self.displayKeyString(for: screen)
        visible = true
        startActivityTimer()
        Log.debug(String(format: "show: setup=%.1fms prevFrontPID=%d title=\"%@\" cached=%@",
                         (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                         prevFrontPID, prevFrontTitle as NSString,
                         cachedShareable == nil ? "no" : "yes"))

        if let cached = cachedShareable {
            renderOverlay(content: cached, screen: screen)
            prewarmShareable()
        } else {
            Task { await prepareAndShow() }
        }
    }

    private func renderOverlay(content: SCShareableContent, screen: NSScreen) {
        guard visible else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let displayBounds = CGDisplayBounds(Self.displayID(for: screen))
        let visibleFrame = screen.visibleFrame
        let candidates = content.windows
            .filter(Self.isCapturable)
            .filter { Self.windowMostlyOn(displayBounds: displayBounds, window: $0) }
        let tFilter = CFAbsoluteTimeGetCurrent()
        let createdWindow = window == nil
        let w = window ?? makeWindow(frame: visibleFrame)
        window = w
        w.setFrame(visibleFrame, display: false)
        if config.animations {
            w.alphaValue = 0
        } else {
            w.alphaValue = 1
        }
        let tWindow = CFAbsoluteTimeGetCurrent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        installTiles(candidates: candidates)
        CATransaction.commit()
        let tTiles = CFAbsoluteTimeGetCurrent()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let v = view { w.makeFirstResponder(v) }
        let tFront = CFAbsoluteTimeGetCurrent()
        if config.animations {
            w.fadeInAndUp(distance: 0, duration: 0.10)
        }
        animateShowFromFocused(in: w)
        let tEnd = CFAbsoluteTimeGetCurrent()
        Log.debug(String(format: "render: filter=%.1f window=%.1f(new=%@) installTiles=%.1f orderFront+activate=%.1f animate=%.1f total=%.1f n=%d",
                         (tFilter - t0) * 1000,
                         (tWindow - tFilter) * 1000, createdWindow ? "yes" : "no",
                         (tTiles - tWindow) * 1000,
                         (tFront - tTiles) * 1000,
                         (tEnd - tFront) * 1000,
                         (tEnd - t0) * 1000,
                         candidates.count))
    }

    private static func cursorScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    private static func displayKeyString(for screen: NSScreen) -> String {
        let id = displayID(for: screen)
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let cf = CFUUIDCreateString(nil, uuidRef) as String? {
            return cf
        }
        return "id-\(id)"
    }

    private func startActivityTimer() {
        activityTimer?.invalidate()
        guard config.livePreviewsEnabled else { return }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            for t in self.allTiles { t.updateActivity(now: now) }
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
        guard let content = scContent else { return }
        await MainActor.run {
            self.cachedShareable = content
            self.cachedShareableAt = CFAbsoluteTimeGetCurrent()
            let s = self.activeScreen ?? Self.cursorScreen()
            self.renderOverlay(content: content, screen: s)
        }
    }

    private static let smoothEasing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    private static let pickDuration: Double = 0.16

    private func suspendFrames() {
        for t in allTiles { t.suppressFrames = true }
    }

    private func resumeFrames(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            for t in self.allTiles { t.suppressFrames = false }
        }
    }

    private func animateShowFromFocused(in w: NSWindow) {
        guard tiles.indices.contains(selectedIndex),
              let bounds = w.contentView?.bounds, bounds.width > 0 else { return }
        guard config.animations else { return }
        let tile = tiles[selectedIndex]
        let gridFrame = tile.layer.frame

        suspendFrames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.highlight = .none
        tile.layer.zPosition = 1
        tile.setFrame(bounds)
        CATransaction.commit()
        CATransaction.flush()

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.pickDuration)
        CATransaction.setAnimationTimingFunction(Self.smoothEasing)
        tile.setFrame(gridFrame)
        CATransaction.commit()

        resumeFrames(after: Self.pickDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickDuration) { [weak self, weak tile] in
            tile?.layer.zPosition = 0
            self?.updateSelection()
        }
    }

private static func windowMostlyOn(displayBounds: CGRect, window: SCWindow) -> Bool {
        let inter = window.frame.intersection(displayBounds)
        guard !inter.isNull else { return false }
        let interArea = inter.width * inter.height
        let total = window.frame.width * window.frame.height
        return total > 0 && interArea / total >= 0.5
    }

    private func installTiles(candidates: [SCWindow]) {
        let mcTiles: [Tile] = candidates.compactMap { w -> Tile? in
            guard let pid = w.owningApplication?.processID else { return nil }
            return Tile(scWindow: w, ownerPID: pid)
        }

        let saved = savedOrder
        let ordered: [Tile]
        if config.usageOrderingEnabled {
            let usage = Self.usageOrder
            let usageRanks = Dictionary(uniqueKeysWithValues: usage.enumerated().map { ($1, $0) })
            let savedRanks = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1, $0) })
            ordered = mcTiles.sorted { a, b in
                let ar = usageRanks[Self.usageKey(for: a)] ?? Int.max
                let br = usageRanks[Self.usageKey(for: b)] ?? Int.max
                if ar != br { return ar < br }
                let asr = savedRanks[CGWindowID(a.scWindow.windowID)] ?? Int.max
                let bsr = savedRanks[CGWindowID(b.scWindow.windowID)] ?? Int.max
                if asr != bsr { return asr < bsr }
                return a.scWindow.windowID < b.scWindow.windowID
            }
        } else if saved.isEmpty {
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
        let widMatch = prevPickedWindowID.flatMap { wid in tiles.firstIndex(where: { CGWindowID($0.scWindow.windowID) == wid }) }
        let titleMatch = tiles.firstIndex(where: { $0.ownerPID == prevFrontPID && ($0.scWindow.title ?? "") == prevFrontTitle })
        let pidMatch = tiles.firstIndex(where: { $0.ownerPID == prevFrontPID })
        if let i = widMatch ?? titleMatch ?? pidMatch {
            selectedIndex = i
            updateSelection()
        }
        let live = config.livePreviewsEnabled
        let delay: TimeInterval = config.animations ? Self.pickDuration + 0.05 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [ordered] in
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for t in ordered {
                        group.addTask {
                            await t.snapshot()
                            if live { await t.start() }
                        }
                    }
                }
            }
        }
    }

    private func rebuildDisplayed() {
        let ignored = ignoredKeys
        let displayed = allTiles.filter { showIgnored ? true : !ignored.contains($0.ignoreKey) }
        for t in allTiles {
            let isIgnored = ignored.contains(t.ignoreKey)
            t.layer.isHidden = showIgnored ? false : isIgnored
            t.layer.opacity = (showIgnored && isIgnored) ? 0.3 : 1.0
            t.setNumber(nil)
            t.tintColorName = paneColors[CGWindowID(t.scWindow.windowID)]
        }
        tiles = displayed
        for (i, t) in tiles.enumerated() {
            t.setNumber(i < 9 ? i + 1 : nil)
        }
        let bounds = window?.contentView?.bounds ?? .zero
        layoutTiles(in: bounds)
        if !tiles.indices.contains(selectedIndex) {
            selectedIndex = max(0, tiles.count - 1)
        }
        updateSelection()
    }

    private func tagSelectedColor(_ name: String?) {
        guard tiles.indices.contains(selectedIndex) else { return }
        let id = CGWindowID(tiles[selectedIndex].scWindow.windowID)
        if let name { paneColors[id] = name } else { paneColors.removeValue(forKey: id) }
        tiles[selectedIndex].tintColorName = name
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

    private func toggleShowIgnored() {
        showIgnored.toggle()
        rebuildDisplayed()
        layoutTilesAnimated()
        updateHint()
    }

    private func selectApp(startingWith letter: String) {
        guard config.letterJumpEnabled, !tiles.isEmpty else { return }
        let needle = letter.lowercased()
        let start = lastLetterJump == needle ? selectedIndex + 1 : 0
        let order = Array(start..<tiles.count) + Array(0..<min(start, tiles.count))
        guard let match = order.first(where: { idx in
            (tiles[idx].scWindow.owningApplication?.applicationName ?? "")
                .lowercased()
                .hasPrefix(needle)
        }) else { return }
        lastLetterJump = needle
        selectedIndex = match
        updateSelection()
    }

    private func dispatch(_ action: Action) {
        switch action {
        case .pick: pick()
        case .dismiss:
            if showIgnored { toggleShowIgnored() } else { dismiss() }
        case .moveLeft:  move(dx: -1, dy: 0)
        case .moveRight: move(dx: 1, dy: 0)
        case .moveUp:    move(dx: 0, dy: -1)
        case .moveDown:  move(dx: 0, dy: 1)
        case .swapLeft:  swapSelected(dx: -1, dy: 0)
        case .swapRight: swapSelected(dx: 1, dy: 0)
        case .swapUp:    swapSelected(dx: 0, dy: -1)
        case .swapDown:  swapSelected(dx: 0, dy: 1)
        case .ignore: toggleIgnoreSelected()
        case .toggleHidden: toggleShowIgnored()
        case .close: closeSelected()
        case .tagGreen:  tagSelectedColor("green")
        case .tagBlue:   tagSelectedColor("blue")
        case .tagRed:    tagSelectedColor("red")
        case .tagYellow: tagSelectedColor("yellow")
        case .tagOrange: tagSelectedColor("orange")
        case .tagPurple: tagSelectedColor("purple")
        case .tagClear:  tagSelectedColor(nil)
        case .pick1: pickIndex(0)
        case .pick2: pickIndex(1)
        case .pick3: pickIndex(2)
        case .pick4: pickIndex(3)
        case .pick5: pickIndex(4)
        case .pick6: pickIndex(5)
        case .pick7: pickIndex(6)
        case .pick8: pickIndex(7)
        case .pick9: pickIndex(8)
        }
    }

    private func closeSelected() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let tile = tiles[selectedIndex]
        let pid = tile.ownerPID
        let windowID = CGWindowID(tile.scWindow.windowID)
        pressCloseButton(pid: pid, windowID: windowID)

        let removed = tile
        tiles.remove(at: selectedIndex)
        allTiles.removeAll { $0 === removed }
        removed.layer.removeFromSuperlayer()
        Task { await removed.stop() }

        savedOrder = allTiles.map { CGWindowID($0.scWindow.windowID) }
        if !tiles.indices.contains(selectedIndex) {
            selectedIndex = max(0, tiles.count - 1)
        }
        renumberTiles()
        layoutTilesAnimated()
        updateSelection()
    }

    private func pressCloseButton(pid: pid_t, windowID: CGWindowID) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowID {
                var btnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
                   let btn = btnRef, CFGetTypeID(btn) == AXUIElementGetTypeID() {
                    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
                }
                return
            }
        }
    }

    private func updateHint() {
        guard let win = window, let root = win.contentView?.layer else { return }
        if showIgnored {
            hint.show(text: "Hidden      ⌘⌫  toggle      esc  exit", in: root, bounds: win.contentView?.bounds ?? .zero)
        } else {
            hint.hide()
        }
    }

    func shutdown() {
        let toStop = allTiles
        allTiles = []
        tiles = []
        guard !toStop.isEmpty else { return }
        let group = DispatchGroup()
        for t in toStop { t.stopSync(group: group) }
        _ = group.wait(timeout: .now() + 1.0)
    }

    private func hide(activatePrevious: Bool = true) {
        let toStop = allTiles
        for t in toStop { t.suppressFrames = true }
        stopActivityTimer()
        let w = window
        let animate = config.animations && w != nil && w!.alphaValue > 0
        visible = false
        if activatePrevious, prevFrontPID != 0,
           let app = NSRunningApplication(processIdentifier: prevFrontPID) {
            app.activate()
        }
        prevFrontPID = 0
        tiles = []
        allTiles = []
        selectedIndex = 0
        showIgnored = false
        lastLetterJump = nil
        view?.resetMomentaryPeek()
        hint.hide()
        Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for t in toStop {
                    group.addTask(priority: .utility) { await t.stop() }
                }
            }
        }
        isZoomed = false
        savedFrames = []
        let clearLayers = { [weak self] in
            if let root = self?.window?.contentView?.layer {
                root.sublayers?.forEach { $0.removeFromSuperlayer() }
            }
        }
        if animate, let w {
            w.fadeOutAndDown(distance: 0, duration: 0.10) { [weak self] in
                guard let self else { return }
                if !self.visible {
                    w.orderOut(nil)
                    clearLayers()
                }
            }
        } else {
            w?.orderOut(nil)
            clearLayers()
        }
        hint.reset()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.prewarmShareable()
        }
    }


    private func pickIndex(_ n: Int) {
        guard tiles.indices.contains(n) else { return }
        selectedIndex = n
        updateSelection()
        pick()
    }

    private func layoutTiles(in bounds: NSRect) {
        let screenSize = activeScreen?.frame.size ?? NSScreen.main?.frame.size ?? bounds.size
        let ar = screenSize.width / max(1, screenSize.height)
        let (rects, cols) = GridLayout.frames(count: tiles.count, bounds: bounds, aspectRatio: ar)
        gridCols = cols
        for (tile, cell) in zip(tiles, rects) {
            let src = tile.scWindow.frame
            let srcAR = src.width / max(1, src.height)
            let cellAR = cell.width / max(1, cell.height)
            let fitted: CGRect
            if srcAR > cellAR {
                let h = cell.width / srcAR
                fitted = CGRect(x: cell.minX, y: cell.midY - h / 2, width: cell.width, height: h)
            } else {
                let w = cell.height * srcAR
                fitted = CGRect(x: cell.midX - w / 2, y: cell.minY, width: w, height: cell.height)
            }
            tile.setFrame(fitted)
        }
    }

    private func updateSelection() {
        for (i, t) in tiles.enumerated() {
            t.highlight = (i == selectedIndex) ? .subtle : .none
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
        guard tiles.indices.contains(selectedIndex), !isPicking else { return }
        let tile = tiles[selectedIndex]
        let pid = tile.ownerPID
        let windowID = CGWindowID(tile.scWindow.windowID)
        let title = tile.scWindow.title
        prevFrontPID = 0
        prevPickedWindowID = windowID
        isPicking = true

        raiseAXWindow(pid: pid, windowID: windowID, title: title)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        raiseAXWindow(pid: pid, windowID: windowID, title: title)

        guard let w = window, let bounds = w.contentView?.bounds, config.animations else {
            hide(activatePrevious: false)
            isPicking = false
            return
        }

        suspendFrames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.highlight = .none
        tile.layer.zPosition = 1
        CATransaction.commit()
        CATransaction.flush()

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.pickDuration)
        CATransaction.setAnimationTimingFunction(Self.smoothEasing)
        tile.setFrame(bounds)
        CATransaction.commit()
        _ = w

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickDuration) { [weak self] in
            guard let self else { return }
            self.hide(activatePrevious: false)
            self.isPicking = false
        }
    }

    private func raiseAXWindow(pid: pid_t, windowID: CGWindowID, title: String?) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowID {
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, win)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                return
            }
        }
        guard let title, !title.isEmpty else { return }
        for win in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            if let t = titleRef as? String, t == title {
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, win)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                return
            }
        }
    }

    private func mouseDownAt(_ point: NSPoint) {
        if isZoomed {
            dragState = nil
            pick()
            return
        }
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
        guard newCol >= 0, newCol < cols, newRow >= 0 else { return }
        let target = newRow * cols + newCol
        guard target >= 0, target < tiles.count, target != selectedIndex else { return }
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
        suspendFrames()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        layoutTiles(in: bounds)
        CATransaction.commit()
        resumeFrames(after: 0.18)
    }

    private func beginZoom() {
        guard !isZoomed, tiles.indices.contains(selectedIndex) else { return }
        let bounds = window?.contentView?.bounds ?? .zero
        let pad: CGFloat = 4
        let avail = bounds.insetBy(dx: pad, dy: pad)
        let src = tiles[selectedIndex].scWindow.frame
        let srcAR = src.width / max(1, src.height)
        let availAR = avail.width / max(1, avail.height)
        let target: CGRect
        if srcAR > availAR {
            let h = avail.width / srcAR
            target = CGRect(x: avail.minX, y: avail.midY - h / 2, width: avail.width, height: h)
        } else {
            let w = avail.height * srcAR
            target = CGRect(x: avail.midX - w / 2, y: avail.minY, width: w, height: avail.height)
        }
        savedFrames = tiles.map { $0.layer.frame }
        isZoomed = true
        suspendFrames()
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
        resumeFrames(after: 0.12)
    }

    private func endZoom() {
        guard isZoomed else { return }
        isZoomed = false
        suspendFrames()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (i, t) in tiles.enumerated() {
            if i < savedFrames.count { t.setFrame(savedFrames[i]) }
            t.layer.zPosition = 0
            t.layer.opacity = 1
        }
        CATransaction.commit()
        resumeFrames(after: 0.12)
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
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        w.isOpaque = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = OverlayView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        v.keymap = Keymap(overrides: config.bindings)
        v.onAction = { [weak self] action in self?.dispatch(action) }
        v.onSpaceDown = { [weak self] in self?.beginZoom() }
        v.onSpaceUp = { [weak self] in self?.endZoom() }
        v.onMouseDown = { [weak self] p in self?.mouseDownAt(p) }
        v.onMouseDragged = { [weak self] p in self?.mouseDraggedAt(p) }
        v.onMouseUp = { [weak self] p in self?.mouseUpAt(p) }
        v.onLetter = { [weak self] letter in self?.selectApp(startingWith: letter) }
        w.contentView = v
        view = v
        return w
    }
}
