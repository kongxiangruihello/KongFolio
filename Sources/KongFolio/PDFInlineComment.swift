import AppKit
import PDFKit

enum PDFInlineComment {
    private static let anchorKey = PDFAnnotationKey(rawValue: "KFInlineCommentAnchor")
    private static let styleKey = PDFAnnotationKey(rawValue: "KFInlineCommentStyle")

    static func isCard(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "FreeText" && annotation.value(forAnnotationKey: anchorKey) is String
    }

    static func anchor(of annotation: PDFAnnotation) -> CGRect? {
        guard isCard(annotation), let value = annotation.value(forAnnotationKey: anchorKey) as? String else { return nil }
        let rect = NSRectFromString(value)
        return rect.isEmpty || rect.isInfinite ? nil : rect
    }

    static func style(of annotation: PDFAnnotation) -> PDFCommentStyle {
        if let value = annotation.value(forAnnotationKey: styleKey) as? String,
           let saved = try? JSONDecoder().decode(PDFCommentStyle.self, from: Data(value.utf8)) {
            return saved.normalized
        }
        var style = PDFCommentStyle()
        guard isCard(annotation) else { return style }
        let width = annotation.bounds.width
        if width.isFinite, width >= 80 { style.width = Int(min(width, 1200).rounded()) }
        if let font = annotation.font, font.pointSize.isFinite {
            style.fontSize = Int(min(max(font.pointSize, 8), 72).rounded())
        }
        if let ink = annotation.fontColor.flatMap(PDFCommentStyle.rgb) { style.textColor = ink }
        if let fill = PDFCommentStyle.rgb(annotation.color) { style.backgroundColor = fill }
        style.transparent = annotation.color.alphaComponent == 0
        if let border = annotation.border, border.lineWidth > 0 {
            style.frame = border.style == .dashed ? .dashed : .solid
        } else {
            style.frame = .none
        }
        return style
    }

    static func card(for text: String, anchor: CGRect, on page: PDFPage, quote: String?,
                     style: PDFCommentStyle, position: CGPoint? = nil) -> PDFAnnotation {
        let bounds = cardBounds(for: text, anchor: anchor, on: page, style: style, position: position)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        apply(style, text: text, to: annotation)
        annotation.setValue(NSStringFromRect(anchor), forAnnotationKey: anchorKey)
        if let quote, !quote.isEmpty { annotation.setValue(quote, forAnnotationKey: ReadingServices.quoteKey) }
        return annotation
    }

    static func cardBounds(for text: String, anchor: CGRect, on page: PDFPage, style: PDFCommentStyle,
                           existing: PDFAnnotation? = nil, position: CGPoint? = nil) -> CGRect {
        if let existing, !isCard(existing) { return existing.bounds }
        let box = page.bounds(for: .cropBox)
        let size = cardSize(text, style: style, in: box)
        let width = size.width
        let height = size.height
        let origin = position ?? existing.map { CGPoint(x: $0.bounds.minX, y: $0.bounds.maxY) }
        if let origin {
            return contained(CGRect(x: origin.x, y: origin.y - height, width: width, height: height), in: box)
        }
        let gap: CGFloat = 10
        let canUseRight = anchor.maxX + gap + width <= box.maxX - 6
        let canUseLeft = anchor.minX - gap - width >= box.minX + 6
        let x = canUseRight ? anchor.maxX + gap : canUseLeft ? anchor.minX - gap - width : anchor.minX
        let lowerEdge = anchor.minY - height - gap
        let y = canUseRight || canUseLeft ? anchor.maxY - height
            : lowerEdge >= box.minY + 6 ? lowerEdge : anchor.maxY + gap
        return contained(CGRect(x: x, y: y, width: width, height: height), in: box)
    }

    static func update(_ annotation: PDFAnnotation, text: String, style: PDFCommentStyle, bounds: CGRect) {
        guard isCard(annotation) else { annotation.contents = text; return }
        annotation.bounds = bounds
        apply(style, text: text, to: annotation)
    }

    private static func apply(_ style: PDFCommentStyle, text: String, to annotation: PDFAnnotation) {
        annotation.removeValue(forAnnotationKey: .appearanceDictionary)
        annotation.contents = text
        annotation.font = style.font
        annotation.fontColor = style.ink
        annotation.alignment = style.alignment.native
        annotation.color = style.fill
        let border = PDFBorder()
        border.lineWidth = style.frame == .none ? 0 : 1
        if style.frame == .dashed {
            border.style = .dashed
            border.dashPattern = [4, 3]
        }
        annotation.border = border
        if let data = try? JSONEncoder().encode(style) {
            annotation.setValue(String(decoding: data, as: UTF8.self), forAnnotationKey: styleKey)
        }
    }

    private static func cardSize(_ text: String, style: PDFCommentStyle, in box: CGRect) -> CGSize {
        let width = min(CGFloat(style.width), max(1, box.width - 12))
        let availableHeight = max(1, box.height - 12)
        if !style.automaticHeight {
            return CGSize(width: width, height: min(CGFloat(style.height), availableHeight))
        }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width - 16), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: style.font]
        )
        return CGSize(width: width, height: min(availableHeight, max(28, ceil(rect.height) + 16)))
    }

    private static func contained(_ rect: CGRect, in page: CGRect) -> CGRect {
        let margin = min(6, page.width / 4, page.height / 4)
        let available = page.insetBy(dx: margin, dy: margin)
        let width = min(rect.width, available.width)
        let height = min(rect.height, available.height)
        return CGRect(x: min(max(available.minX, rect.minX), available.maxX - width),
                      y: min(max(available.minY, rect.minY), available.maxY - height),
                      width: width, height: height)
    }
}

@MainActor extension Workspace {
    @discardableResult
    func saveInlineComment(_ text: String, page: PDFPage, anchor: CGRect, quote: String? = nil,
                           existing: PDFAnnotation? = nil, highlight: PDFSelection? = nil,
                           style: PDFCommentStyle? = nil, position: CGPoint? = nil) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !busy, !readingLocked, page.document === document else { return false }
        if let existing {
            guard existing.page === page else { return false }
            let unchangedStyle = PDFInlineComment.style(of: existing)
            let requested = style?.normalized ?? unchangedStyle
            let bounds = PDFInlineComment.cardBounds(for: content, anchor: anchor, on: page, style: requested,
                                                     existing: existing, position: position)
            let geometryChanged = position != nil && bounds != existing.bounds
            if existing.contents != content || (PDFInlineComment.isCard(existing) && (requested != unchangedStyle || geometryChanged)) {
                let edit = beginAnnotationEdit([existing])
                guard !edit.isEmpty else { return false }
                PDFInlineComment.update(existing, text: content, style: requested, bounds: bounds)
                commitAnnotationEdit(edit)
                if selectedAnnotation === existing { note = content }
            }
        } else {
            let comment = PDFInlineComment.card(for: content, anchor: anchor, on: page, quote: quote,
                                                style: (style ?? PDFCommentStyle()).normalized, position: position)
            let highlights = highlight.map { addMarkup($0, style: .highlight, color: markupColor, note: "") } ?? []
            page.addAnnotation(comment)
            recordAnnotationsAdded(highlights + [comment])
        }
        status = "PDF 评论已保存"
        pdfView?.needsDisplay = true
        return true
    }
}
