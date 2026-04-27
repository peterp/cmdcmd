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
    private var showIgnored: Bool = false
    private var dragState: DragState?
    private var lastLetterJump: String?
    private let tracker: SpaceTracker
    private var config: Config

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

    private static var usageOrder: [String] {
        get { (UserDefaults.standard.array(forKey: "appUsageOrder") as? [String]) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(128)), forKey: "appUsageOrder") }
    }

    private var workspaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var activityTimer: Timer?
    private var keyEventTap: CFMachPort?
    private var keyEventTapRunLoopSource: CFRunLoopSource?
    private let hint = HintPill()

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

    func updateConfig(_ config: Config) {
        self.config = config
        view?.keymap = Keymap(overrides: config.bindings, vimBindings: config.vimBindings)
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
        let prevApp = NSWorkspace.shared.frontmostApplication
        prevFrontPID = prevApp?.processIdentifier ?? 0
        if let prevApp { Self.recordUse(of: prevApp) }
        prevFrontTitle = focusedWindowTitle(pid: prevFrontPID) ?? ""
        let screen = Self.cursorScreen()
        activeScreen = screen
        displayKey = Self.displayKeyString(for: screen)
        visible = true
        startActivityTimer()
        startKeyEventTap()
        Task { await prepareAndShow() }
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
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            for t in self.allTiles { t.updateActivity(now: now) }
        }
    }

    private func startKeyEventTap() {
        stopKeyEventTap()
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let overlay = Unmanaged<Overlay>.fromOpaque(userInfo).takeUnretainedValue()
            guard overlay.visible, let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            return overlay.handleTappedKeyEvent(nsEvent, type: type) ? nil : Unmanaged.passUnretained(event)
        }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: ref) else {
            Log.write("overlay key event tap unavailable")
            return
        }
        keyEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopKeyEventTap() {
        if let keyEventTap { CGEvent.tapEnable(tap: keyEventTap, enable: false) }
        if let keyEventTapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyEventTapRunLoopSource, .commonModes) }
        keyEventTap = nil
        keyEventTapRunLoopSource = nil
    }

    private func handleTappedKeyEvent(_ event: NSEvent, type: CGEventType) -> Bool {
        let run = {
            if type == .keyDown { return self.view?.handleKeyDown(event) == true }
            if type == .keyUp { return self.view?.handleKeyUp(event) == true }
            return false
        }
        if Thread.isMainThread { return run() }
        return DispatchQueue.main.sync(execute: run)
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
        let frames: (display: CGRect, visible: CGRect) = await MainActor.run {
            let s = self.activeScreen ?? Self.cursorScreen()
            return (CGDisplayBounds(Self.displayID(for: s)), s.visibleFrame)
        }
        if config.minimalMode {
            let candidates = tracker.windows().filter(Self.isCapturableMinimal).filter { Self.windowMostlyOn(displayBounds: frames.display, window: $0) }
            await MainActor.run {
                guard visible else { return }
                let panelFrame = minimalPanelFrame(tileCount: candidates.count, visibleFrame: frames.visible)
                let w = window ?? makeWindow(frame: panelFrame)
                window = w
                w.setFrame(panelFrame, display: false)
                w.alphaValue = 1
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                if let v = view {
                    w.makeFirstResponder(v)
                    DispatchQueue.main.async { w.makeFirstResponder(v) }
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                installMinimalTiles(candidates: candidates)
                CATransaction.commit()
                if config.animations {
                    w.fadeInAndUp(distance: 28, duration: 0.125)
                }
            }
            return
        }
        let scContent: SCShareableContent?
        do {
            scContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            Log.write("SCShareableContent failed: \(error)")
            scContent = nil
        }
        let allCandidates = (scContent?.windows ?? []).filter(Self.isCapturable)
        let candidates = allCandidates.filter { Self.windowMostlyOn(displayBounds: frames.display, window: $0) }

        await MainActor.run {
            guard visible else { return }
            let w = window ?? makeWindow(frame: frames.visible)
            window = w
            w.setFrame(frames.visible, display: false)
            w.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            if let v = view {
                w.makeFirstResponder(v)
                DispatchQueue.main.async { w.makeFirstResponder(v) }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            installTiles(candidates: candidates)
            CATransaction.commit()
            animateShowFromFocused(in: w)
        }
    }

    private static let smoothEasing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    private static let pickDuration: Double = 0.16

    private func animateShowFromFocused(in w: NSWindow) {
        guard tiles.indices.contains(selectedIndex), config.animations else { return }
        if config.minimalMode {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(Self.smoothEasing)
            for t in tiles { t.layer.opacity = 1 }
            CATransaction.commit()
            return
        }
        guard let bounds = w.contentView?.bounds, bounds.width > 0 else { return }
        let tile = tiles[selectedIndex]
        let gridFrame = tile.layer.frame

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

    private static func windowMostlyOn(displayBounds: CGRect, window: SpaceWindow) -> Bool {
        let inter = window.bounds.intersection(displayBounds)
        guard !inter.isNull else { return false }
        let interArea = inter.width * inter.height
        let total = window.bounds.width * window.bounds.height
        return total > 0 && interArea / total >= 0.5
    }

    private func minimalPanelFrame(tileCount: Int, visibleFrame: CGRect) -> CGRect {
        let count = max(1, tileCount)
        let target: CGFloat = 64
        let gap: CGFloat = 12
        let padX: CGFloat = 22
        let padY: CGFloat = 18
        let maxCols = max(1, Int((visibleFrame.width * 0.72 - padX * 2 + gap) / (target + gap)))
        let cols = min(count, maxCols)
        let rows = Int(ceil(Double(count) / Double(cols)))
        let width = CGFloat(cols) * target + CGFloat(max(0, cols - 1)) * gap + padX * 2
        let height = CGFloat(rows) * target + CGFloat(max(0, rows - 1)) * gap + padY * 2
        return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2 + 42, width: width, height: height)
    }

    private func installMinimalTiles(candidates: [SpaceWindow]) {
        installOrderedTiles(candidates.map { Tile(spaceWindow: $0) })
    }

    private func installTiles(candidates: [SCWindow]) {
        let mcTiles: [Tile] = candidates.compactMap { w -> Tile? in
            guard let pid = w.owningApplication?.processID else { return nil }
            return Tile(scWindow: w, ownerPID: pid, minimalMode: config.minimalMode)
        }

        installOrderedTiles(mcTiles)
    }

    private func installOrderedTiles(_ mcTiles: [Tile]) {
        let saved = savedOrder
        let usage = Self.usageOrder
        let savedRanks = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($0.element, $0.offset) })
        let usageRanks = Dictionary(uniqueKeysWithValues: usage.enumerated().map { ($0.element, $0.offset) })
        let ordered = mcTiles.sorted { a, b in
            let ar = usageRanks[Self.usageKey(for: a)] ?? Int.max
            let br = usageRanks[Self.usageKey(for: b)] ?? Int.max
            if ar != br { return ar < br }
            let asr = savedRanks[a.windowID] ?? Int.max
            let bsr = savedRanks[b.windowID] ?? Int.max
            if asr != bsr { return asr < bsr }
            return a.windowID < b.windowID
        }
        savedOrder = ordered.map { $0.windowID }

        allTiles = ordered
        for t in ordered {
            view?.layer?.addSublayer(t.layer)
        }
        rebuildDisplayed()
        if let i = tiles.firstIndex(where: { $0.ownerPID == prevFrontPID && ($0.sourceTitle ?? "") == prevFrontTitle })
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
        let displayed = allTiles.filter { showIgnored ? true : !ignored.contains($0.ignoreKey) }
        for t in allTiles {
            let isIgnored = ignored.contains(t.ignoreKey)
            t.layer.isHidden = showIgnored ? false : isIgnored
            t.layer.opacity = (showIgnored && isIgnored) ? 0.3 : 1.0
            t.setNumber(nil)
            t.tintColorName = paneColors[t.windowID]
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
        let id = tiles[selectedIndex].windowID
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

    private func selectApp(startingWith letter: String) {
        guard config.letterJump, !tiles.isEmpty else { return }
        let needle = letter.lowercased()
        let start = lastLetterJump == needle ? selectedIndex + 1 : 0
        let orderedIndices = Array(start..<tiles.count) + Array(0..<min(start, tiles.count))
        guard let match = orderedIndices.first(where: { index in
            tiles[index].ownerName.lowercased().hasPrefix(needle)
        }) else { return }
        lastLetterJump = needle
        selectedIndex = match
        updateSelection()
    }

    private func closeSelected() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let tile = tiles[selectedIndex]
        let pid = tile.ownerPID
        let windowID = tile.windowID
        pressCloseButton(pid: pid, windowID: windowID)

        let removed = tile
        tiles.remove(at: selectedIndex)
        allTiles.removeAll { $0 === removed }
        removed.layer.removeFromSuperlayer()
        Task { await removed.stop() }

        savedOrder = allTiles.map { $0.windowID }
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
        stopActivityTimer()
        stopKeyEventTap()
        window?.orderOut(nil)
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
        view?.resetMomentaryPeek()
        lastLetterJump = nil
        hint.hide()
        Task {
            for t in toStop {
                t.layer.removeFromSuperlayer()
                await t.stop()
            }
        }
        isZoomed = false
        savedFrames = []
        hint.reset()
    }


    private func pickIndex(_ n: Int) {
        guard tiles.indices.contains(n) else { return }
        selectedIndex = n
        updateSelection()
        pick()
    }

    private func layoutTiles(in bounds: NSRect) {
        if config.minimalMode {
            let target: CGFloat = 64
            let gap: CGFloat = 12
            let cols = min(max(1, tiles.count), max(1, Int((bounds.width - 44 + gap) / (target + gap))))
            let rows = Int(ceil(Double(tiles.count) / Double(cols)))
            let totalWidth = CGFloat(cols) * target + CGFloat(max(0, cols - 1)) * gap
            let totalHeight = CGFloat(rows) * target + CGFloat(max(0, rows - 1)) * gap
            let startX = bounds.midX - totalWidth / 2
            let startY = bounds.midY - totalHeight / 2
            gridCols = cols
            for (i, tile) in tiles.enumerated() {
                let col = i % cols
                let row = i / cols
                tile.setFrame(CGRect(
                    x: startX + CGFloat(col) * (target + gap),
                    y: startY + CGFloat(rows - row - 1) * (target + gap),
                    width: target,
                    height: target
                ))
            }
            return
        }
        let screenSize = activeScreen?.frame.size ?? NSScreen.main?.frame.size ?? bounds.size
        let ar = screenSize.width / max(1, screenSize.height)
        let (rects, cols) = GridLayout.frames(count: tiles.count, bounds: bounds, aspectRatio: ar)
        gridCols = cols
        for (tile, cell) in zip(tiles, rects) {
            let src = tile.sourceFrame
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
        let windowID = tile.windowID
        let title = tile.sourceTitle
        prevFrontPID = 0
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

        if config.minimalMode {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            CATransaction.setAnimationTimingFunction(Self.smoothEasing)
            w.alphaValue = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                w.alphaValue = 1
                self.hide(activatePrevious: false)
                self.isPicking = false
            }
            return
        }

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
        _ = bounds

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
                savedOrder = tiles.map { $0.windowID }
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
        savedOrder = tiles.map { $0.windowID }
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
        let thumbHeight = min(max(bounds.height * 0.12, 64), 110)
        let pad: CGFloat = 18
        let avail = bounds.insetBy(dx: pad, dy: pad).insetBy(dx: 0, dy: thumbHeight * 0.45)
        let src = tiles[selectedIndex].sourceFrame
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
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(Self.smoothEasing)
        let others = tiles.enumerated().filter { $0.offset != selectedIndex }
        let thumbWidth = min(150, max(70, (bounds.width - pad * 2) / CGFloat(max(1, others.count))))
        let totalWidth = thumbWidth * CGFloat(others.count)
        var x = bounds.midX - totalWidth / 2
        for (i, t) in tiles.enumerated() {
            if i == selectedIndex {
                t.layer.zPosition = 10
                t.layer.opacity = 1
                t.setFrame(target)
            } else {
                t.layer.zPosition = 0
                t.layer.opacity = 0.38
                let original = savedFrames.indices.contains(i) ? savedFrames[i] : t.layer.frame
                let ar = original.width / max(1, original.height)
                let w = min(thumbWidth - 8, thumbHeight * ar)
                let frame = CGRect(x: x + (thumbWidth - w) / 2, y: pad, width: w, height: thumbHeight)
                t.setFrame(frame)
                x += thumbWidth
            }
        }
        CATransaction.commit()
    }

    private func endZoom() {
        guard isZoomed else { return }
        isZoomed = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(Self.smoothEasing)
        for (i, t) in tiles.enumerated() {
            if i < savedFrames.count { t.setFrame(savedFrames[i]) }
            t.layer.zPosition = 0
            t.layer.opacity = 1
        }
        CATransaction.commit()
        savedFrames = []
    }

    private static func recordUse(of app: NSRunningApplication) {
        guard app.processIdentifier != getpid(), app.activationPolicy == .regular else { return }
        let key = usageKey(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        var order = usageOrder.filter { $0 != key }
        order.insert(key, at: 0)
        usageOrder = order
    }

    private static func usageKey(for tile: Tile) -> String {
        usageKey(pid: tile.ownerPID, bundleIdentifier: tile.ownerBundleIdentifier)
    }

    private static func usageKey(pid: pid_t, bundleIdentifier: String?) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return "pid:\(pid)"
    }

    private static func isCommandTabApp(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
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
        guard isCommandTabApp(pid: app.processID) else { return false }
        if w.frame.width < 200 || w.frame.height < 200 { return false }
        if !w.isOnScreen && w.windowLayer != 0 { return false }
        return true
    }

    private static func isCapturableMinimal(_ w: SpaceWindow) -> Bool {
        if w.ownerPID == getpid() { return false }
        if systemOwners.contains(w.ownerName) { return false }
        guard isCommandTabApp(pid: w.ownerPID) else { return false }
        if w.bounds.width < 200 || w.bounds.height < 200 { return false }
        return true
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let w = OverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = config.minimalMode ? NSColor.clear.cgColor : NSColor.black.withAlphaComponent(0.18).cgColor
        if config.minimalMode {
            let blur = NSVisualEffectView(frame: container.bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 25
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 1
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            container.addSubview(blur)
        }
        let v = OverlayView(frame: container.bounds)
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        v.keymap = Keymap(overrides: config.bindings, vimBindings: config.vimBindings)
        v.onAction = { [weak self] action in self?.dispatch(action) }
        v.onSpaceDown = { [weak self] in self?.beginZoom() }
        v.onSpaceUp = { [weak self] in self?.endZoom() }
        v.onMouseDown = { [weak self] p in self?.mouseDownAt(p) }
        v.onMouseDragged = { [weak self] p in self?.mouseDraggedAt(p) }
        v.onMouseUp = { [weak self] p in self?.mouseUpAt(p) }
        v.onLetter = { [weak self] letter in self?.selectApp(startingWith: letter) }
        container.addSubview(v)
        w.contentView = container
        view = v
        return w
    }
}
