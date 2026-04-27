import AppKit

enum AppIcon {
    static func makePlaceholder(side: CGFloat = 512) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let bgRadius = side * (110.0 / 512.0)
        let bg = NSBezierPath(roundedRect: rect, xRadius: bgRadius, yRadius: bgRadius)
        NSColor.black.setFill()
        bg.fill()

        let innerInset = side * (10.0 / 512.0)
        let inner = rect.insetBy(dx: innerInset, dy: innerInset)
        let strokeRadius = side * (100.0 / 512.0)
        let stroke = NSBezierPath(roundedRect: inner, xRadius: strokeRadius, yRadius: strokeRadius)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        stroke.lineWidth = max(1, side * (2.0 / 512.0))
        stroke.stroke()

        let text = "⌘⌘"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * (240.0 / 512.0), weight: .regular),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .kern: -side * (8.0 / 512.0),
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2 - side * (8.0 / 512.0),
            width: textSize.width,
            height: textSize.height
        )
        attr.draw(in: textRect)

        return image
    }

    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries: [(name: String, side: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for entry in entries {
            let img = makePlaceholder(side: CGFloat(entry.side))
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(entry.name)"])
            }
            try png.write(to: dir.appendingPathComponent(entry.name))
        }
    }
}
