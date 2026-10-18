import AppKit
import PDFKit
import SwiftUI

/// Builds the annotation a drag on the page makes, so the shapes can be tested without a window.
enum AnnotationShapes {
    /// The end of a straight stroke pulled to the nearest multiple of 15° (what holding Shift does).
    static func snapped(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return end }
        let step = CGFloat.pi / 12
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// The box between two corners; `square` makes it as wide as it is high (a circle for the ellipse tool).
    static func box(from start: CGPoint, to end: CGPoint, square: Bool) -> CGRect {
        var dx = end.x - start.x, dy = end.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
    }

    /// The annotation for the stroke so far (`points` runs from where the mouse went down to where it is now).
    static func make(tool: AnnotationTool, points: [CGPoint], style: PenStyle, color: NSColor, fill: Bool, constrained: Bool) -> PDFAnnotation? {
        guard let start = points.first, let last = points.last else { return nil }
        let annotation: PDFAnnotation
        let border = PDFBorder()
        border.lineWidth = style.width
        switch tool {
        case .line, .arrow:
            let end = constrained ? snapped(from: start, to: last) : last
            let pad = max(6, style.width * 3)
            let bounds = CGRect(x: min(start.x, end.x) - pad, y: min(start.y, end.y) - pad, width: abs(end.x - start.x) + pad * 2, height: abs(end.y - start.y) + pad * 2)
            annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
            annotation.endLineStyle = tool == .arrow ? .openArrow : .none
        case .rectangle, .ellipse:
            let shape = box(from: start, to: last, square: constrained)
            let bounds = shape.insetBy(dx: -style.width / 2 - 1, dy: -style.width / 2 - 1)
            annotation = PDFAnnotation(bounds: bounds, forType: tool == .rectangle ? .square : .circle, withProperties: nil)
            if fill { annotation.interiorColor = color.withAlphaComponent(0.2) }
        case .pen, .signature:
            let xs = points.map(\.x), ys = points.map(\.y)
            let bounds = CGRect(x: xs.min()! - 3, y: ys.min()! - 3, width: xs.max()! - xs.min()! + 6, height: ys.max()! - ys.min()! + 6)
            annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
            for p in points.dropFirst() { path.line(to: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
            annotation.add(path)
        default:
            return nil
        }
        annotation.color = color.withAlphaComponent(style.alpha)
        annotation.border = border
        return annotation
    }
}

extension AnnotationTool {
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .edit: return "pencil.and.outline"
        case .note: return "note.text"
        case .textBox: return "textformat"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .signature: return "signature"
        case .region: return "viewfinder"
        }
    }
}

/// Text for a new note or text box, asked for right where it is placed.
@MainActor enum AnnotationText {
    static func ask(note: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = note ? "批注内容" : "文字框内容"
        alert.informativeText = "输入后点“添加”；以后可以用“编辑标注”改文字、颜色和位置。"
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        field.font = NSFont.systemFont(ofSize: 14)
        field.isRichText = false
        let scroll = NSScrollView(frame: field.frame)
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// A text box tall enough for its text at 14 pt in a 220 pt wide box.
    static func boxHeight(for text: String) -> CGFloat {
        let lines = text.components(separatedBy: .newlines).reduce(0) { $0 + max(1, Int((Double($1.count) * 14 / 204).rounded(.up))) }
        return CGFloat(max(1, lines)) * 18 + 12
    }
}
