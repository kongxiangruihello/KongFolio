import AppKit
import CoreText
import PDFKit

/// PDF copies for handing a document on: with all, some or none of the reader's annotations, and a list of the notes
/// as pages of their own (to print, or to read beside the book).
enum AnnotationExport {
    static let nonMarkup: Set<String> = ["Link", "Widget", "Popup"]

    static func isMarkup(_ annotation: PDFAnnotation) -> Bool { !nonMarkup.contains(annotation.type ?? "") }

    /// A copy of the document in which the markup annotations are limited to those `isKept` accepts; nil keeps all of
    /// them, `{ _ in false }` makes a clean copy. Links and form fields stay either way. Annotations are judged on the
    /// copy itself, so the indexes the notes list reports are those of the file as written.
    static func copy(of document: PDFDocument, keeping isKept: ((AnnotationNote) -> Bool)?) -> PDFDocument? {
        guard let data = document.dataRepresentation(), let duplicate = PDFDocument(data: data) else { return nil }
        guard let isKept else { return duplicate }
        let kept = Set(ReadingServices.notes(duplicate).filter(isKept).map(\.id))
        for pageIndex in 0..<duplicate.pageCount {
            guard let page = duplicate.page(at: pageIndex) else { continue }
            let annotations = page.annotations
            for index in annotations.indices.reversed() where isMarkup(annotations[index]) && !kept.contains("\(pageIndex)-\(index)") {
                page.removeAnnotation(annotations[index])
            }
        }
        return duplicate
    }

    /// The text of the notes list, by chapter when the document has a table of contents.
    static func listText(title: String, notes: [AnnotationNote], outline: [OutlineEntry]) -> String {
        NotesOutline.plainText(title: title, sections: NotesOutline.sections(notes: notes, outline: outline)).replacingOccurrences(of: "笔记大纲", with: "批注清单")
    }

    /// Plain text laid out on A4 pages.
    static func textPages(_ text: String, size: CGSize = CGSize(width: 595, height: 842), margin: CGFloat = 56) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 2
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "PingFang SC", size: 11) ?? NSFont.systemFont(ofSize: 11),
            .paragraphStyle: style,
            .foregroundColor: NSColor.black,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let area = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: area, transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let shown = CTFrameGetVisibleStringRange(frame).length
            if shown == 0 { break }
            start += shown
        } while start < attributed.length
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    /// `document` with the pages of `extra` appended (copies; neither argument is changed).
    static func appending(_ extra: PDFDocument, to document: PDFDocument) -> PDFDocument? {
        guard let result = copy(of: document, keeping: nil) else { return nil }
        for index in 0..<extra.pageCount {
            if let page = extra.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        return result
    }
}

extension Workspace {
    enum AnnotationPDF {
        case clean              // no annotations at all
        case annotatedWithList  // everything, plus the notes list at the end
        case listOnly           // the notes list alone
        case filtered           // only what the notes list currently shows
    }

    func exportAnnotationPDF(_ mode: AnnotationPDF) {
        guard count > 0, checkDraftsForExport() else { return }
        showAllLayers()
        let notes = ReadingServices.notes(document)
        let shown = noteFilter.apply(to: notes)
        if mode != .clean, notes.isEmpty { error = "这份文档里没有标注。"; return }
        if mode == .filtered, shown.isEmpty { error = "当前筛选没有符合的标注。"; return }
        let listed = mode == .filtered ? shown : notes
        let suffix: String
        switch mode {
        case .clean: suffix = "干净副本"
        case .annotatedWithList: suffix = "含批注清单"
        case .listOnly: suffix = "批注清单"
        case .filtered: suffix = "筛选的标注"
        }
        guard let url = saveURL(type: .pdf, suffix: "pdf", name: title + "-" + suffix) else { return }
        report {
            let result: PDFDocument?
            let list = { AnnotationExport.textPages(AnnotationExport.listText(title: self.title, notes: listed, outline: self.outlineEntries)) }
            switch mode {
            case .clean: result = AnnotationExport.copy(of: document, keeping: { _ in false })
            case .filtered: result = AnnotationExport.copy(of: document, keeping: { self.noteFilter.matches($0) })
            case .annotatedWithList: result = list().flatMap { AnnotationExport.appending($0, to: document) }
            case .listOnly: result = list()
            }
            guard let data = result?.dataRepresentation() else { throw FolioError(message: "无法生成 PDF。") }
            try data.write(to: url, options: .atomic)
            status = "已导出：\(url.lastPathComponent)"
        }
    }
}
