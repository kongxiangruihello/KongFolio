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

/// The drawing tools within reach of the page, so lines and marks do not depend on the side panel.
struct AnnotationBar: View {
    @ObservedObject var workspace: Workspace

    private struct Entry: Identifiable {
        let id: String
        let tool: AnnotationTool
        let highlighter: Bool
        let symbol: String
        let help: String
    }

    private let entries: [Entry] = [
        Entry(id: "select", tool: .select, highlighter: false, symbol: "cursorarrow", help: "选择 / 阅读"),
        Entry(id: "pen", tool: .pen, highlighter: false, symbol: "pencil.tip", help: "画笔：自由画线"),
        Entry(id: "marker", tool: .pen, highlighter: true, symbol: "highlighter", help: "荧光笔：宽而半透明的线"),
        Entry(id: "line", tool: .line, highlighter: false, symbol: "line.diagonal", help: "直线（按住 Shift 取 15° 的倍数）"),
        Entry(id: "arrow", tool: .arrow, highlighter: false, symbol: "arrow.up.right", help: "箭头"),
        Entry(id: "rectangle", tool: .rectangle, highlighter: false, symbol: "rectangle", help: "矩形（按住 Shift 画正方形）"),
        Entry(id: "ellipse", tool: .ellipse, highlighter: false, symbol: "circle", help: "椭圆（按住 Shift 画圆）"),
        Entry(id: "text", tool: .textBox, highlighter: false, symbol: "textformat", help: "文字框：点一下页面，输入文字"),
        Entry(id: "note", tool: .note, highlighter: false, symbol: "note.text", help: "批注图标：点一下页面，输入文字"),
        Entry(id: "edit", tool: .edit, highlighter: false, symbol: "pencil.and.outline", help: "编辑标注：点选后拖动、改色、删除"),
    ]
    private let swatches: [(name: String, color: Color)] = [("红", .red), ("橙", .orange), ("黄", .yellow), ("绿", .green), ("蓝", .blue), ("黑", .black)]

    private func active(_ entry: Entry) -> Bool {
        guard workspace.tool == entry.tool else { return false }
        return entry.tool != .pen || workspace.penHighlighter == entry.highlighter
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(entries) { entry in
                Button {
                    workspace.tool = entry.tool
                    if entry.tool == .pen { workspace.penHighlighter = entry.highlighter }
                } label: {
                    Image(systemName: entry.symbol).frame(width: 26, height: 24)
                        .background(active(entry) ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(entry.help)
            }
            Divider().frame(height: 20)
            ForEach(swatches, id: \.name) { swatch in
                Button { workspace.annotationColor = swatch.color } label: {
                    Circle().fill(swatch.color).frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.primary, lineWidth: workspace.annotationColor == swatch.color ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }
            ColorPicker("", selection: $workspace.annotationColor, supportsOpacity: false).labelsHidden().frame(width: 28)
            Menu {
                ForEach([1.0, 2.0, 3.0, 5.0, 8.0], id: \.self) { width in
                    Button("\(Int(width)) 磅") { workspace.penWidth = width }
                }
            } label: { Image(systemName: "lineweight") }
                .menuStyle(.borderlessButton).frame(width: 34).help("线宽（现在 \(workspace.penWidth, format: .number.precision(.fractionLength(1))) 磅）")
            Toggle(isOn: $workspace.shapeFill) { Image(systemName: "square.fill") }
                .toggleStyle(.button).buttonStyle(.plain).help("矩形、椭圆填充半透明颜色")
            Divider().frame(height: 20)
            Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(!workspace.canUndo).help("撤销")
            Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.plain).disabled(!workspace.canRedo).help("重做")
            Button { workspace.showAnnotationBar = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起工具栏（标注菜单里可以再打开）")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}
