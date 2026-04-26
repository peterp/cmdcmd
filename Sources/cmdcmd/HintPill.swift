import AppKit

/// A small text pill anchored to the bottom-center of the overlay,
/// used to surface mode hints like "Focus" or "Hidden".
final class HintPill {
    private var layer: CATextLayer?

    func show(text: String, in parent: CALayer, bounds: CGRect) {
        let l = layer ?? makeLayer()
        if layer == nil {
            parent.addSublayer(l)
            layer = l
        }
        l.string = text
        l.isHidden = false
        layout(in: bounds)
    }

    func hide() {
        layer?.isHidden = true
    }

    /// Drop the cached layer reference. Call after the parent layer has
    /// been wiped (e.g. on overlay teardown) so the next show() builds fresh.
    func reset() {
        layer = nil
    }

    private func layout(in bounds: CGRect) {
        guard let l = layer else { return }
        let text = (l.string as? String) ?? ""
        let attrs: [NSAttributedString.Key: Any] = [
            .font: l.font as? NSFont ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        let pad: CGFloat = 18
        let height: CGFloat = 26
        let width = ceil(textWidth) + pad * 2
        l.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: 24,
            width: width,
            height: height
        )
    }

    private func makeLayer() -> CATextLayer {
        let h = CATextLayer()
        h.alignmentMode = .center
        h.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        h.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        h.cornerRadius = 10
        h.masksToBounds = true
        h.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        h.fontSize = 12
        h.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return h
    }
}
