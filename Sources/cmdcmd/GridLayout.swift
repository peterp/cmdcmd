import CoreGraphics
import Foundation

enum GridLayout {
    static func frames(count: Int, bounds: CGRect, aspectRatio: CGFloat, padding: CGFloat = 24) -> (frames: [CGRect], cols: Int) {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return ([], 1) }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let ar = max(0.01, aspectRatio)

        let availW = (bounds.width - padding * CGFloat(cols + 1)) / CGFloat(cols)
        let availH = (bounds.height - padding * CGFloat(rows + 1)) / CGFloat(rows)
        let tileW: CGFloat
        let tileH: CGFloat
        if availW / availH > ar {
            tileH = availH
            tileW = tileH * ar
        } else {
            tileW = availW
            tileH = tileW / ar
        }

        let totalW = tileW * CGFloat(cols) + padding * CGFloat(cols - 1)
        let totalH = tileH * CGFloat(rows) + padding * CGFloat(rows - 1)
        let originX = (bounds.width - totalW) / 2
        let originY = (bounds.height - totalH) / 2

        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        for i in 0..<count {
            let col = i % cols
            let row = i / cols
            let x = originX + CGFloat(col) * (tileW + padding)
            let y = bounds.height - originY - CGFloat(row + 1) * tileH - CGFloat(row) * padding
            rects.append(CGRect(x: x, y: y, width: tileW, height: tileH))
        }
        return (rects, cols)
    }
}
