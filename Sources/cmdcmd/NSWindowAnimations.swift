import AppKit

extension NSWindow {
    func fadeInAndUp(distance: CGFloat = 50, duration: TimeInterval = 0.125, callback: (() -> Void)? = nil) {
        let toFrame = frame
        let fromFrame = NSRect(x: toFrame.minX, y: toFrame.minY - distance, width: toFrame.width, height: toFrame.height)
        setFrame(fromFrame, display: true)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            animator().alphaValue = 1
            animator().setFrame(toFrame, display: true)
        } completionHandler: {
            callback?()
        }
    }

    func fadeOutAndDown(distance: CGFloat = 50, duration: TimeInterval = 0.125, callback: (() -> Void)? = nil) {
        let fromFrame = frame
        let toFrame = NSRect(x: fromFrame.minX, y: fromFrame.minY - distance, width: fromFrame.width, height: fromFrame.height)
        setFrame(fromFrame, display: true)
        alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            animator().alphaValue = 0
            animator().setFrame(toFrame, display: true)
        } completionHandler: {
            callback?()
        }
    }
}
