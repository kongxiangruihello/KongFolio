import AppKit
import CoreText
import PDFKit

enum PageNumberFormat: String, Codable, CaseIterable, Identifiable {
    case none = "无"
    case plain = "1"
    case chinese = "第 1 页"
    case ofTotal = "1 / 总页数"
    var id: String { rawValue }
}

enum PageNumberPosition: String, Codable, CaseIterable, Identifiable {
    case bottomCenter = "底部居中"
    case bottomRight = "底部右侧"
    case topCenter = "顶部居中"
    case topRight = "顶部右侧"
    var id: String { rawValue }
}

/// Page numbers, a header, a footer and a diagonal watermark drawn onto exported PDF pages.
struct StampOptions: Equatable, Codable {
    var numberFormat = PageNumberFormat.none
    var numberPosition = PageNumberPosition.bottomCenter
    var startNumber = 1
    var header = ""
    var footer = ""
    var watermark = ""
    var fontSize = 10.0

    var isActive: Bool {
        numberFormat != .none || [header, footer, watermark].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum Stamping {
    static let margin: CGFloat = 30

    static func numberText(_ format: PageNumberFormat, number: Int, last: Int) -> String? {
        switch format {
        case .none: return nil
        case .plain: return "\(number)"
        case .chinese: return "第 \(number) 页"
        case .ofTotal: return "\(number) / \(last)"
        }
    }

    /// Redraws `pages` of `doc` with the stamps on top and returns the new PDF. The page content stays vector
    /// (text remains selectable and searchable) and the outline is carried over; annotations are flattened into
    /// the page and links stop being clickable, because the pages are drawn rather than edited in place.
    static func apply(_ stamp: StampOptions, to doc: PDFDocument, pages: [Int]) throws -> PDFDocument {
        let data = NSMutableData()
        var first = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &first, nil) else {
            throw FolioError(message: "无法创建带页码的 PDF。")
        }
        let last = stamp.startNumber + pages.count - 1
        for (offset, index) in pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let page = try doc.page(at: index).unwrap("页面读取失败")
                let reference = try page.pageRef.unwrap("无法读取 PDF 页面内容。")
                let crop = page.bounds(for: .cropBox)
                let quarterTurn = abs(page.rotation % 180) == 90
                var box = CGRect(origin: .zero, size: quarterTurn ? CGSize(width: crop.height, height: crop.width) : crop.size)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.saveGState()
                context.concatenate(reference.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(reference)
                for annotation in page.annotations where !["Link", "Widget", "Popup"].contains(annotation.type ?? "") {
                    annotation.draw(with: .cropBox, in: context)
                }
                context.restoreGState()
                draw(stamp, number: stamp.startNumber + offset, last: last, in: box, context: context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        let output = try PDFDocument(data: data as Data).unwrap("带页码的 PDF 生成失败。")
        let outline = ReadingServices.outline(doc).compactMap { entry -> OutlineEntry? in
            guard let position = pages.firstIndex(of: entry.page) else { return nil }
            var copy = entry; copy.page = position; return copy
        }
        ReadingServices.applyOutline(outline, to: output)
        return output
    }

    private enum Alignment { case left, center, right }

    private static func line(_ text: String, size: CGFloat, gray: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): TextImport.font(size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    private static func text(_ string: String, size: CGFloat, alignment: Alignment, top: Bool, in box: CGRect, context: CGContext) {
        let typeset = line(string, size: size, gray: 0.25)
        let w = width(typeset)
        let x: CGFloat
        switch alignment {
        case .left: x = margin
        case .center: x = (box.width - w) / 2
        case .right: x = box.width - margin - w
        }
        context.textPosition = CGPoint(x: x, y: top ? box.height - margin - size * 0.8 : margin - size * 0.2)
        CTLineDraw(typeset, context)
    }

    static func draw(_ stamp: StampOptions, number: Int, last: Int, in box: CGRect, context: CGContext) {
        let size = CGFloat(min(max(stamp.fontSize, 6), 24))
        let mark = stamp.watermark.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mark.isEmpty {
            // Fit the text to 70% of the page diagonal, then rotate it along the diagonal.
            let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
            let probe = line(mark, size: 100, gray: 0.5)
            let fitted = min(120, max(16, 100 * diagonal * 0.7 / max(1, width(probe))))
            let typeset = line(mark, size: fitted, gray: 0.5)
            context.saveGState()
            context.setAlpha(0.18)
            context.translateBy(x: box.midX, y: box.midY)
            context.rotate(by: atan2(box.height, box.width))
            context.textPosition = CGPoint(x: -width(typeset) / 2, y: -fitted * 0.3)
            CTLineDraw(typeset, context)
            context.restoreGState()
        }
        let header = stamp.header.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty { text(header, size: size, alignment: .left, top: true, in: box, context: context) }
        let footer = stamp.footer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !footer.isEmpty { text(footer, size: size, alignment: .left, top: false, in: box, context: context) }
        if let label = numberText(stamp.numberFormat, number: number, last: last) {
            let top = stamp.numberPosition == .topCenter || stamp.numberPosition == .topRight
            let alignment: Alignment = stamp.numberPosition == .bottomRight || stamp.numberPosition == .topRight ? .right : .center
            text(label, size: size, alignment: alignment, top: top, in: box, context: context)
        }
    }
}
