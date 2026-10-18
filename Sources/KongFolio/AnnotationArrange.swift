import AppKit
import PDFKit

enum AnnotationAlignment { case left, right, top, bottom, centerX, centerY }

/// Aligning and spacing marks on one page (PDF coordinates: the origin is bottom-left, "top" is the larger y).
enum AnnotationLayout {
    static func align(_ rects: [CGRect], _ how: AnnotationAlignment) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        return rects.map { rect in
            var moved = rect
            switch how {
            case .left: moved.origin.x = union.minX
            case .right: moved.origin.x = union.maxX - rect.width
            case .top: moved.origin.y = union.maxY - rect.height
            case .bottom: moved.origin.y = union.minY
            case .centerX: moved.origin.x = union.midX - rect.width / 2
            case .centerY: moved.origin.y = union.midY - rect.height / 2
            }
            return moved
        }
    }

    /// The outermost two stay where they are; the ones between get equal gaps. Returned in the order given.
    static func distribute(_ rects: [CGRect], horizontally: Bool) -> [CGRect] {
        guard rects.count > 2 else { return rects }
        let order = rects.indices.sorted { horizontally ? rects[$0].minX < rects[$1].minX : rects[$0].minY < rects[$1].minY }
        let first = rects[order[0]], last = rects[order[order.count - 1]]
        let total = horizontally ? last.maxX - first.minX : last.maxY - first.minY
        let used = order.reduce(CGFloat(0)) { $0 + (horizontally ? rects[$1].width : rects[$1].height) }
        let gap = (total - used) / CGFloat(order.count - 1)
        var result = rects
        var cursor = horizontally ? first.minX : first.minY
        for index in order {
            if horizontally { result[index].origin.x = cursor; cursor += rects[index].width + gap }
            else { result[index].origin.y = cursor; cursor += rects[index].height + gap }
        }
        return result
    }

    /// Marks whose position is just their bounds; markup that follows text (highlights, lines, ink) is left where it is.
    static func canMove(_ annotation: PDFAnnotation) -> Bool { ["FreeText", "Square", "Circle", "Text", "Stamp"].contains(annotation.type ?? "") }
}

/// Typeface, size, border and fill of a text box.
enum AnnotationTextStyle {
    static let fonts: [(name: String, title: String)] = [("", "系统字体"), ("Songti SC", "宋体"), ("Kaiti SC", "楷体"), ("Heiti SC", "黑体")]
    static let sizes: [CGFloat] = [10, 12, 14, 18, 24, 32]
    static let fills: [(title: String, color: NSColor)] = [
        ("无底色", .clear), ("浅黄", NSColor(red: 1, green: 0.96, blue: 0.7, alpha: 1)), ("浅绿", NSColor(red: 0.85, green: 0.96, blue: 0.85, alpha: 1)),
        ("浅蓝", NSColor(red: 0.85, green: 0.92, blue: 1, alpha: 1)), ("白色", .white),
    ]

    nonisolated static func font(name: String, size: CGFloat) -> NSFont {
        (name.isEmpty ? nil : NSFont(name: name, size: size)) ?? NSFont.systemFont(ofSize: size)
    }

    /// Height of a box `width` wide for `text` set at `size` (CJK characters count as a full em, other text as half).
    nonisolated static func height(for text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let usable = max(size, width - 16)
        var lines = 0
        for line in text.components(separatedBy: .newlines) {
            let em = line.reduce(CGFloat(0)) { $0 + (ExcerptText.isCJK($1) ? size : size * 0.55) }
            lines += max(1, Int((em / usable).rounded(.up)))
        }
        return CGFloat(max(1, lines)) * (size * 1.3) + 12
    }
}

extension Workspace {
    /// The annotations that are ticked in the list, grouped by page.
    private var tickedByPage: [[PDFAnnotation]] {
        var groups: [Int: [PDFAnnotation]] = [:]
        for annotation in annotations(ofNotes: selectedNoteIDs) where AnnotationLayout.canMove(annotation) {
            guard let page = annotation.page else { continue }
            let index = document.index(for: page)
            if index != NSNotFound { groups[index, default: []].append(annotation) }
        }
        return groups.keys.sorted().compactMap { groups[$0] }
    }

    func arrangeSelectedNotes(_ change: ([CGRect]) -> [CGRect], minimum: Int) {
        let groups = tickedByPage.filter { $0.count >= minimum }
        guard !groups.isEmpty else { status = "对齐需要同一页上至少 \(minimum) 个文字框、批注图标、矩形或椭圆（高亮、线条、手写不移动）"; return }
        let all = groups.flatMap { $0 }
        let edits = beginAnnotationEdit(all)
        for group in groups {
            let moved = change(group.map(\.bounds))
            for (annotation, rect) in zip(group, moved) { annotation.bounds = rect }
        }
        commitAnnotationEdit(edits)
        status = "已排列 \(all.count) 个标注（可撤销）"
    }

    func alignSelectedNotes(_ how: AnnotationAlignment) { arrangeSelectedNotes({ AnnotationLayout.align($0, how) }, minimum: 2) }
    func distributeSelectedNotes(horizontally: Bool) { arrangeSelectedNotes({ AnnotationLayout.distribute($0, horizontally: horizontally) }, minimum: 3) }

    /// Changes the text box being edited (and the ticked text boxes, if any).
    func styleTextBoxes(font name: String? = nil, size: CGFloat? = nil, fill: NSColor? = nil, border: CGFloat? = nil) {
        var targets = annotations(ofNotes: selectedNoteIDs).filter { $0.type == "FreeText" }
        if targets.isEmpty, let one = selectedAnnotation, one.type == "FreeText" { targets = [one] }
        guard !targets.isEmpty else { status = "先选中一个文字框（用“编辑标注”点选，或在列表里勾选）"; return }
        let edits = beginAnnotationEdit(targets)
        for box in targets {
            let current = box.font ?? NSFont.systemFont(ofSize: 14)
            let family = name ?? (AnnotationTextStyle.fonts.first { !$0.name.isEmpty && current.fontName.hasPrefix($0.name.replacingOccurrences(of: " ", with: "")) }?.name ?? "")
            let points = size ?? current.pointSize
            box.font = AnnotationTextStyle.font(name: family, size: points)
            if size != nil {
                var frame = box.bounds
                let height = AnnotationTextStyle.height(for: box.contents ?? "", size: points, width: frame.width)
                frame.origin.y += frame.height - height
                frame.size.height = height
                box.bounds = frame
            }
            if let fill { box.color = fill }
            if let border {
                let line = PDFBorder()
                line.lineWidth = border
                box.border = border > 0 ? line : nil
            }
        }
        commitAnnotationEdit(edits)
        status = "已修改 \(targets.count) 个文字框（可撤销）"
    }

    // MARK: Layers

    /// Hides or shows one kind of annotation on every page (the file is written with everything visible).
    func setLayer(_ kind: String, visible: Bool) {
        if visible { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
        applyLayers()
    }

    func showAllLayers() {
        guard !hiddenKinds.isEmpty else { return }
        hiddenKinds = []
        applyLayers()
    }

    func applyLayers() {
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where AnnotationExport.isMarkup(annotation) {
                annotation.shouldDisplay = !hiddenKinds.contains(ReadingServices.kindName(for: annotation.type))
            }
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        pdfView?.layoutDocumentView()
    }
}
