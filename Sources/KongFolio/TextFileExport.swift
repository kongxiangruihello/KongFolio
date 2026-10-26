import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

/// Exports the editor's current text, including edits that have not yet been saved.
enum TextFileExport {
    static func attributed(_ text: String, format: TextDocumentFormat) throws -> NSAttributedString {
        if format == .html {
            return try NSAttributedString(data: Data(text.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
        return format == .markdown ? TextImport.markdown(text) : TextImport.plainText(text)
    }
    static func writeWord(_ text: String, format: TextDocumentFormat, to destination: URL) throws {
        let content = try attributed(text, format: format)
        let raw = content.string as NSString
        var paragraphs: [String] = [], relationships = "", linkNumber = 1
        var location = 0
        while location < raw.length {
            let line = raw.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(line)
            while end > line.location, CharacterSet.newlines.contains(UnicodeScalar(raw.character(at: end - 1)) ?? " ") { end -= 1 }
            var runs = "", largest: CGFloat = 12
            content.enumerateAttributes(in: NSRange(location: line.location, length: end - line.location)) { attributes, range, _ in
                var size: CGFloat = 12, bold = false, italic = false
                if format == .html {
                    if let font = attributes[.font] as? NSFont {
                        size = font.pointSize
                        let traits = NSFontManager.shared.traits(of: font)
                        bold = traits.contains(.boldFontMask); italic = traits.contains(.italicFontMask)
                    }
                } else if let value = attributes[TextImport.fontKey] {
                    let font = value as! CTFont
                    size = CTFontGetSize(font)
                    let traits = CTFontGetSymbolicTraits(font)
                    bold = traits.contains(.boldTrait); italic = traits.contains(.italicTrait) || abs(CTFontGetMatrix(font).c) > 0.01
                }
                largest = max(largest, size)
                var style = "<w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"宋体\"/><w:sz w:val=\"\(Int(size * 2))\"/>"
                if bold { style += "<w:b/>" }; if italic { style += "<w:i/>" }
                if attributes[.underlineStyle] != nil { style += "<w:u w:val=\"single\"/>" }
                let value = raw.substring(with: range).components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(WordExport.escape($0))</w:t>" }.joined(separator: "<w:tab/>")
                let run = "<w:r><w:rPr>\(style)</w:rPr>\(value)</w:r>"
                if let link = attributes[.link], let url = (link as? URL) ?? URL(string: String(describing: link)), ["http", "https", "mailto", "file", "kongfolio"].contains(url.scheme?.lowercased() ?? "") {
                    let id = "link\(linkNumber)"; linkNumber += 1
                    relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(WordExport.escape(url.absoluteString).replacingOccurrences(of: "\"", with: "&quot;"))\" TargetMode=\"External\"/>"
                    runs += "<w:hyperlink r:id=\"\(id)\">\(run)</w:hyperlink>"
                } else { runs += run }
            }
            let heading = largest >= 21 ? 1 : largest >= 17 ? 2 : largest >= 15 ? 3 : 0
            let style = heading > 0 ? "<w:pStyle w:val=\"Heading\(heading)\"/>" : ""
            paragraphs.append("<w:p><w:pPr>\(style)<w:spacing w:after=\"120\"/></w:pPr>\(runs)</w:p>")
            location = NSMaxRange(line)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let zip = try ZipWriter(url: temporary)
        do {
            try zip.add("[Content_Types].xml", Data(WordExport.contentTypes.utf8))
            try zip.add("_rels/.rels", Data(WordExport.rootRelationships.utf8))
            try zip.add("word/styles.xml", Data(WordExport.styles.utf8))
            let document = WordExport.header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>" + paragraphs.joined() + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1417\" w:right=\"1417\" w:bottom=\"1417\" w:left=\"1417\"/></w:sectPr></w:body></w:document>"
            try zip.add("word/document.xml", Data(document.utf8))
            let rels = WordExport.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" + relationships + "</Relationships>"
            try zip.add("word/_rels/document.xml.rels", Data(rels.utf8)); try zip.finish()
            try Data(contentsOf: temporary).write(to: destination, options: .atomic)
        } catch { zip.abandon(); throw error }
    }
}

extension MarkdownNote {
    func writePDF(to url: URL) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolioError(message: "文件内容为空，请先输入内容") }
        let document = try renderDocument()
        try document.dataRepresentation().unwrap("PDF 生成失败").write(to: url, options: .atomic)
    }
    func exportWord() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = title + ".docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TextFileExport.writeWord(text, format: format, to: url); status = "已导出可编辑的 Word 文档" }
        catch { self.error = "Word 导出失败：" + error.localizedDescription }
    }
}
