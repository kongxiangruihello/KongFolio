import AppKit
import CoreText
import PDFKit

/// Block pagination shared by editor preview, printing and PDF export. Table cells stay real, selectable text.
enum RichTextPDF {
    static func render(_ document: RichTextDocument) throws -> PDFDocument {
        let data = NSMutableData(); var box = CGRect(origin: .zero, size: TextImport.pageSize)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw FolioError(message: "无法生成 PDF") }
        let margin = CGFloat(document.options.margin), width = box.width - margin * 2, height = box.height - margin * 2
        var y = box.height - margin, pages = 0, opened = false
        func nextPage() throws {
            if opened { context.endPDFPage(); opened = false }
            guard pages < TextImport.maximumPages else { throw FolioError(message: "文本超过最大页数，请拆分文件") }
            context.beginPDFPage(nil); opened = true; pages += 1; y = box.height - margin
        }
        func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
            let setter = CTFramesetterCreateWithAttributedString(text)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            return ceil(size.height) + 3
        }
        func draw(_ text: NSAttributedString, range: CFRange, rect: CGRect) -> Int {
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), range, path, nil)
            CTFrameDraw(frame, context); TextImport.addLinks(in: frame, path: path, to: context)
            return CTFrameGetVisibleStringRange(frame).length
        }
        do {
            try nextPage()
            for block in document.blocks {
                try Task.checkCancellation()
                switch block {
                case .paragraph(let text, let heading):
                    guard text.length > 0 else { continue }
                    if heading > 0, y - margin < CGFloat(document.options.fontSize * 5) { try nextPage() }
                    var location = 0
                    while location < text.length {
                        if y - margin < CGFloat(document.options.fontSize * document.options.lineHeight + 4) { try nextPage() }
                        let visible = draw(text, range: CFRange(location: location, length: 0), rect: CGRect(x: margin, y: margin, width: width, height: y - margin))
                        guard visible > 0 else { throw FolioError(message: "文字无法排入页面，请减小字号或页边距") }
                        let part = text.attributedSubstring(from: NSRange(location: location, length: visible))
                        y -= min(y - margin, textHeight(part, width: width))
                        location += visible
                        if location < text.length { try nextPage() }
                    }
                    y -= heading > 0 ? 10 : 6
                case .image(let data, _):
                    guard let image = SignatureImage.loadData(data) else { throw FolioError(message: "图片无法读取") }
                    let scale = min(width / CGFloat(image.width), (height - 12) / CGFloat(image.height), 1)
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    if y - margin < size.height + 8 { try nextPage() }
                    context.draw(image, in: CGRect(x: margin + (width - size.width) / 2, y: y - size.height, width: size.width, height: size.height)); y -= size.height + 12
                case .table(let rows):
                    let columns = max(1, rows.map(\.count).max() ?? 1), cellWidth = width / CGFloat(columns)
                    guard cellWidth > 16 else { throw FolioError(message: "表格列数过多，请减少列数或页边距") }
                    for row in rows {
                        let cells = (0..<columns).map { $0 < row.count ? row[$0] : NSAttributedString(string: "") }
                        var locations = Array(repeating: 0, count: columns)
                        var first = true
                        while first || zip(locations, cells).contains(where: { $0 < $1.length }) {
                            first = false
                            let remaining = zip(locations, cells).map { location, text in text.attributedSubstring(from: NSRange(location: location, length: text.length - location)) }
                            let natural = (remaining.map { textHeight($0, width: cellWidth - 12) }.max() ?? 0) + 12
                            if y - margin < min(natural, CGFloat(document.options.fontSize * document.options.lineHeight + 20)) { try nextPage() }
                            let rowHeight = min(natural, y - margin)
                            for column in cells.indices {
                                let rect = CGRect(x: margin + CGFloat(column) * cellWidth, y: y - rowHeight, width: cellWidth, height: rowHeight)
                                context.setStrokeColor(CGColor(gray: 0.65, alpha: 1)); context.setLineWidth(0.5); context.stroke(rect)
                                if locations[column] < cells[column].length {
                                    let visible = draw(cells[column], range: CFRange(location: locations[column], length: 0), rect: rect.insetBy(dx: 6, dy: 6))
                                    guard visible > 0 else { throw FolioError(message: "表格单元格无法排版，请减小字号或减少列数") }
                                    locations[column] += visible
                                }
                            }
                            y -= rowHeight
                            if zip(locations, cells).contains(where: { $0 < $1.length }) { try nextPage() }
                        }
                    }
                    y -= 10
                }
            }
            if opened { context.endPDFPage() }; context.closePDF()
        } catch { if opened { context.endPDFPage() }; context.closePDF(); throw error }
        return try PDFDocument(data: data as Data).unwrap("PDF 生成失败")
    }
}
