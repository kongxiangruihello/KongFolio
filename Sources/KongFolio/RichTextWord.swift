import AppKit
import CoreText

enum RichTextWord {
    static func attribute(_ value: String) -> String { WordExport.escape(value).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
    static func write(_ document: RichTextDocument, to destination: URL, academic: AcademicMarkup? = nil) throws {
        var body = "", relationships = "", media: [(String, Data)] = [], linkNumber = 0
        var hasContent = false, hasChapter = false, pageJustMarked = false
        func paragraph(_ content: NSAttributedString, heading: Int = 0) -> String {
            if academic != nil, content.string.hasPrefix(":::page ") {
                let separator = hasContent ? "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" : ""
                hasContent = true; pageJustMarked = true
                return separator + WordExport.textParagraph("原页码：" + String(content.string.dropFirst(8)), gray: true)
            }
            let chapterBreak = academic != nil && heading == 1 && hasChapter && !pageJustMarked
            if academic != nil, heading == 1 { hasChapter = true }
            hasContent = true; pageJustMarked = false
            if let academic, content.string.contains("[^") || content.string.contains("[~") {
                let properties = (heading > 0 ? "<w:pStyle w:val=\"Heading\(min(heading,3))\"/>" : "") + (chapterBreak ? "<w:pageBreakBefore/>" : "")
                return "<w:p><w:pPr>" + properties + "</w:pPr>" + academic.runs(content.string) + "</w:p>"
            }
            if academic != nil, content.string.hasPrefix(":::caption ") { return WordExport.textParagraph(String(content.string.dropFirst(11)), style: "Caption", size: 20, centered: true) }
            var runs = ""
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
                var size = document.options.fontSize, bold = false, italic = false
                if let value = attributes[TextImport.fontKey] {
                    let font = value as! CTFont; size = CTFontGetSize(font)
                    bold = CTFontGetSymbolicTraits(font).contains(.boldTrait); italic = CTFontGetSymbolicTraits(font).contains(.italicTrait) || abs(CTFontGetMatrix(font).c) > 0.01
                }
                let family = attribute(document.options.fontName)
                var style = "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:eastAsia=\"\(family)\"/><w:sz w:val=\"\(Int(size * 2))\"/><w:szCs w:val=\"\(Int(size * 2))\"/>"
                if bold { style += "<w:b/>" }; if italic { style += "<w:i/>" }
                if attributes[TextImport.underlineKey] != nil || attributes[.underlineStyle] != nil { style += "<w:u w:val=\"single\"/>" }
                if let value = attributes[TextImport.colorKey], let rgb = (value as! CGColor).converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components, rgb.count >= 3 {
                    style += "<w:color w:val=\"\(rgb.prefix(3).map { String(format: "%02X", min(255, max(0, Int($0 * 255)))) }.joined())\"/>"
                }
                let value = (content.string as NSString).substring(with: range).components(separatedBy: "\n").map { line in line.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(WordExport.escape($0))</w:t>" }.joined(separator: "<w:tab/>") }.joined(separator: "<w:br/>")
                let run = "<w:r><w:rPr>\(style)</w:rPr>\(value)</w:r>"
                if let link = attributes[.link], let url = (link as? URL) ?? URL(string: String(describing: link)), ["http", "https", "mailto", "file", "kongfolio"].contains(url.scheme?.lowercased() ?? "") {
                    linkNumber += 1; let id = "link\(linkNumber)"
                    relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(attribute(url.absoluteString))\" TargetMode=\"External\"/>"
                    runs += "<w:hyperlink r:id=\"\(id)\">\(run)</w:hyperlink>"
                } else { runs += run }
            }
            let headingStyle = (heading > 0 ? "<w:pStyle w:val=\"Heading\(min(heading, 3))\"/><w:keepNext/>" : "") + (chapterBreak ? "<w:pageBreakBefore/>" : "")
            return "<w:p><w:pPr>\(headingStyle)<w:spacing w:after=\"120\" w:line=\"\(Int(document.options.lineHeight * 240))\" w:lineRule=\"auto\"/></w:pPr>\(runs)</w:p>"
        }
        let contentWidth: Double = Double(TextImport.pageSize.width) - document.options.margin * 2
        let printableHeight: Double = Double(TextImport.pageSize.height) - document.options.margin * 2 - 12
        for block in document.blocks {
            try Task.checkCancellation()
            switch block {
            case .paragraph(let content, let heading): body += paragraph(content, heading: heading)
            case .table(let rows):
                let columns = max(1, rows.map(\.count).max() ?? 1), cellWidth = Int(contentWidth * 20 / Double(columns))
                let grid = String(repeating: "<w:gridCol w:w=\"\(cellWidth)\"/>", count: columns)
                body += "<w:tbl><w:tblPr><w:tblW w:w=\"\(Int(contentWidth * 20))\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"A6A6A6\"/>" }.joined() + "</w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>"
                for row in rows {
                    body += "<w:tr>"
                    for column in 0..<columns { body += "<w:tc><w:tcPr><w:tcW w:w=\"\(cellWidth)\" w:type=\"dxa\"/></w:tcPr>" + paragraph(column < row.count ? row[column] : NSAttributedString(string: "")) + "</w:tc>" }
                    body += "</w:tr>"
                }
                body += "</w:tbl><w:p/>"
            case .image(let data, let alt):
                hasContent = true; pageJustMarked = false
                let image = try SignatureImage.loadData(data).unwrap("图片失效")
                let widthScale: Double = contentWidth / Double(image.width)
                let heightScale: Double = printableHeight / Double(image.height)
                let scale: Double = min(1.0, min(widthScale, heightScale))
                let number = media.count + 1, name = "image\(number).png", id = "image\(number)"
                media.append((name, data))
                relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                body += WordExport.picture(id: number, relationship: id, name: attribute(alt), width: Int(Double(image.width) * scale * 12700), height: Int(Double(image.height) * scale * 12700))
            }
        }
        var extraTypes = ""
        if let academic {
            for (end, empty) in [(false,academic.footnotes.isEmpty),(true,academic.endnotes.isEmpty)] where !empty {
                let name = end ? "endnotes" : "footnotes"
                extraTypes += "<Override PartName=\"/word/\(name).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.\(name)+xml\"/>"
                relationships += "<Relationship Id=\"\(name)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(name)\" Target=\"\(name).xml\"/>"
            }
        }
        let margin = Int(document.options.margin * 20)
        let xml = WordExport.header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>" + body + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\"/></w:sectPr></w:body></w:document>"
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let zip = try ZipWriter(url: temporary)
        do {
            try zip.add("[Content_Types].xml", Data(WordExport.contentTypes.replacingOccurrences(of: "</Types>", with: "<Default Extension=\"png\" ContentType=\"image/png\"/>" + extraTypes + "</Types>").utf8))
            try zip.add("_rels/.rels", Data(WordExport.rootRelationships.utf8)); try zip.add("word/styles.xml", Data((academic == nil ? WordExport.styles : WordExport.styles.replacingOccurrences(of: "</w:styles>", with: "<w:style w:type=\"paragraph\" w:styleId=\"Caption\"><w:name w:val=\"caption\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:sz w:val=\"20\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"FootnoteText\"><w:name w:val=\"footnote text\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:sz w:val=\"20\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"EndnoteText\"><w:name w:val=\"endnote text\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:sz w:val=\"20\"/></w:rPr></w:style></w:styles>")).utf8))
            try zip.add("word/document.xml", Data(xml.utf8))
            try zip.add("word/_rels/document.xml.rels", Data((WordExport.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" + relationships + "</Relationships>").utf8))
            for (name, bytes) in media { try zip.add("word/media/" + name, bytes) }
            if let academic {
                if !academic.footnotes.isEmpty { try zip.add("word/footnotes.xml", Data(academic.notesXML(end: false).utf8)) }
                if !academic.endnotes.isEmpty { try zip.add("word/endnotes.xml", Data(academic.notesXML(end: true).utf8)) }
            }
            try zip.finish(); try Data(contentsOf: temporary).write(to: destination, options: .atomic)
        } catch { zip.abandon(); throw error }
    }
}
