import AppKit
import PDFKit
import SwiftUI

enum PDFInlineComment {
    private static let anchorKey = PDFAnnotationKey(rawValue: "KFInlineCommentAnchor")
    private static let fontSize: CGFloat = 12

    static func isCard(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "FreeText" && annotation.value(forAnnotationKey: anchorKey) is String
    }

    static func anchor(of annotation: PDFAnnotation) -> CGRect? {
        guard isCard(annotation), let value = annotation.value(forAnnotationKey: anchorKey) as? String else { return nil }
        let rect = NSRectFromString(value)
        return rect.isEmpty || rect.isInfinite ? nil : rect
    }

    static func card(for text: String, anchor: CGRect, on page: PDFPage, quote: String?) -> PDFAnnotation {
        let box = page.bounds(for: .cropBox)
        let width = min(220, max(1, box.width - 12))
        let height = fittedHeight(text, width: width, pageHeight: box.height)
        let gap: CGFloat = 10
        let canUseRight = anchor.maxX + gap + width <= box.maxX - 6
        let canUseLeft = anchor.minX - gap - width >= box.minX + 6
        let x = canUseRight ? anchor.maxX + gap : canUseLeft ? anchor.minX - gap - width : anchor.minX
        let lowerEdge = anchor.minY - height - gap
        let y = canUseRight || canUseLeft ? anchor.maxY - height
            : lowerEdge >= box.minY + 6 ? lowerEdge : anchor.maxY + gap
        let bounds = contained(CGRect(x: x, y: y, width: width, height: height), in: box)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont.systemFont(ofSize: fontSize)
        annotation.fontColor = NSColor(srgbRed: 0.10, green: 0.15, blue: 0.22, alpha: 1)
        annotation.color = NSColor(srgbRed: 0.91, green: 0.95, blue: 1, alpha: 1)
        let border = PDFBorder()
        border.lineWidth = 0.65
        annotation.border = border
        annotation.setValue(NSStringFromRect(anchor), forAnnotationKey: anchorKey)
        if let quote, !quote.isEmpty { annotation.setValue(quote, forAnnotationKey: ReadingServices.quoteKey) }
        return annotation
    }

    static func update(_ annotation: PDFAnnotation, text: String, on page: PDFPage) {
        annotation.contents = text
        guard isCard(annotation) else { return }
        let box = page.bounds(for: .cropBox)
        let old = annotation.bounds
        let height = fittedHeight(text, width: old.width, pageHeight: box.height)
        annotation.bounds = contained(CGRect(x: old.minX, y: old.maxY - height, width: old.width, height: height), in: box)
    }

    private static func fittedHeight(_ text: String, width: CGFloat, pageHeight: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width - 16), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        return min(max(1, pageHeight - 12), max(28, ceil(rect.height) + 16))
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

struct PDFInlineCommentEditor: View {
    @State var text: String
    let editing: Bool
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(editing ? "编辑评论" : "添加评论", systemImage: "text.bubble")
                .font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(height: 126)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(focused ? 0.75 : 0.25))
                        .allowsHitTesting(false)
                }
                .focused($focused)
                .accessibilityLabel("评论内容")
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存") { save(trimmedText) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
        .task { focused = true }
    }
}

@MainActor extension Workspace {
    @discardableResult
    func saveInlineComment(_ text: String, page: PDFPage, anchor: CGRect, quote: String? = nil,
                           existing: PDFAnnotation? = nil, highlight: PDFSelection? = nil) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !busy, !readingLocked, page.document === document else { return false }
        if let existing {
            guard existing.page === page else { return false }
            if existing.contents != content {
                let edit = beginAnnotationEdit([existing])
                guard !edit.isEmpty else { return false }
                PDFInlineComment.update(existing, text: content, on: page)
                commitAnnotationEdit(edit)
                if selectedAnnotation === existing { note = content }
            }
        } else {
            let comment = PDFInlineComment.card(for: content, anchor: anchor, on: page, quote: quote)
            let highlights = highlight.map { addMarkup($0, style: .highlight, color: markupColor, note: "") } ?? []
            page.addAnnotation(comment)
            recordAnnotationsAdded(highlights + [comment])
        }
        status = "PDF 评论已保存"
        pdfView?.needsDisplay = true
        return true
    }
}
