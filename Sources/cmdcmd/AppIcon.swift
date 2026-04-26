import AppKit

enum AppIcon {
    static func makePlaceholder() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 110, yRadius: 110)
        NSColor.black.setFill()
        bg.fill()

        let inner = rect.insetBy(dx: 10, dy: 10)
        let stroke = NSBezierPath(roundedRect: inner, xRadius: 100, yRadius: 100)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        stroke.lineWidth = 2
        stroke.stroke()

        let text = "⌘⌘"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 240, weight: .regular),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .kern: -8,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2 - 8,
            width: textSize.width,
            height: textSize.height
        )
        attr.draw(in: textRect)

        return image
    }
}
