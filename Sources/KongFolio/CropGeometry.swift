import Foundation

enum CropGeometry {
    static func clamp(_ value: CGFloat, _ low: CGFloat = 0, _ high: CGFloat = 1) -> CGFloat { min(high, max(low, value)) }
    static func selection(from start: CGPoint, to end: CGPoint, size: CGSize) -> CGRect {
        let a = CGPoint(x: clamp(start.x / max(1, size.width)), y: clamp(start.y / max(1, size.height)))
        let b = CGPoint(x: clamp(end.x / max(1, size.width)), y: clamp(end.y / max(1, size.height)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func move(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: clamp(rect.minX + dx, 0, 1 - rect.width), y: clamp(rect.minY + dy, 0, 1 - rect.height), width: rect.width, height: rect.height)
    }
    static func resize(_ rect: CGRect, anchorX: Int, anchorY: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        if anchorX < 0 { x0 = clamp(x0 + dx, 0, x1 - 0.02) }; if anchorX > 0 { x1 = clamp(x1 + dx, x0 + 0.02, 1) }
        if anchorY < 0 { y0 = clamp(y0 + dy, 0, y1 - 0.02) }; if anchorY > 0 { y1 = clamp(y1 + dy, y0 + 0.02, 1) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    static func imageCoordinates(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height) }
}
