import AppKit
import Foundation
import PDFKit

/// A minimal .zip writer: every entry is stored without compression (the pictures in a Word file are JPEGs already,
/// and the text is small), which keeps the writer short and its output easy to check.
final class ZipWriter {
    private let handle: FileHandle
    private var offset = 0
    private var entries: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = UInt16(((2026 - 1980) << 9) | (1 << 5) | 1)

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt32 in
            var value: UInt32 = 0xFFFFFFFF
            for byte in bytes { value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
            return value ^ 0xFFFFFFFF
        }
    }

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw FolioError(message: "无法创建文件。") }
        handle = try FileHandle(forWritingTo: url)
    }

    func add(_ name: String, _ data: Data) throws {
        guard data.count < 0x7FFF_FFFF, offset < 0x7FFF_FFFF, entries.count < 0xFFF0 else {
            throw FolioError(message: "内容太大，无法写成 .docx。请减少页数，或选择较小的图片尺寸。")
        }
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(data)
        var header = Data()
        header.appendLE32(0x04034b50); header.appendLE16(20); header.appendLE16(0x0800); header.appendLE16(0)
        header.appendLE16(Self.dosTime); header.appendLE16(Self.dosDate)
        header.appendLE32(crc); header.appendLE32(UInt32(data.count)); header.appendLE32(UInt32(data.count))
        header.appendLE16(UInt16(nameBytes.count)); header.appendLE16(0)
        header.append(nameBytes)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        entries.append((nameBytes, crc, UInt32(data.count), UInt32(offset)))
        offset += header.count + data.count
    }

    func finish() throws {
        var directory = Data()
        for entry in entries {
            directory.appendLE32(0x02014b50); directory.appendLE16(20); directory.appendLE16(20); directory.appendLE16(0x0800); directory.appendLE16(0)
            directory.appendLE16(Self.dosTime); directory.appendLE16(Self.dosDate)
            directory.appendLE32(entry.crc); directory.appendLE32(entry.size); directory.appendLE32(entry.size)
            directory.appendLE16(UInt16(entry.name.count)); directory.appendLE16(0); directory.appendLE16(0); directory.appendLE16(0); directory.appendLE16(0)
            directory.appendLE32(0); directory.appendLE32(entry.offset)
            directory.append(entry.name)
        }
        var end = Data()
        end.appendLE32(0x06054b50); end.appendLE16(0); end.appendLE16(0)
        end.appendLE16(UInt16(entries.count)); end.appendLE16(UInt16(entries.count))
        end.appendLE32(UInt32(directory.count)); end.appendLE32(UInt32(offset)); end.appendLE16(0)
        try handle.write(contentsOf: directory)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    /// Stops writing without finishing (the caller removes the partial file).
    func abandon() { try? handle.close() }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func appendLE32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
}

struct WordExportOptions: Equatable, Codable {
    enum Content: String, CaseIterable, Identifiable, Codable {
        case both = "文字和页面图片"
        case textOnly = "仅文字"
        case imagesOnly = "仅页面图片"
        var id: String { rawValue }
    }
    enum ImageSize: String, CaseIterable, Identifiable, Codable {
        case small = "小（文件最小）"
        case standard = "标准"
        case high = "高（文件较大）"
        var id: String { rawValue }
        var pixels: CGFloat { switch self { case .small: return 1000; case .standard: return 1500; case .high: return 2200 } }
        var quality: Double { switch self { case .small: return 0.6; case .standard: return 0.72; case .high: return 0.85 } }
    }
    var content = Content.both
    var imageSize = ImageSize.standard
    /// Lines that belong to one sentence are joined into a paragraph (the text layer of a scan has one line per row).
    var mergeLines = true
    var pageMarks = true
    /// Vertical (竖排) pages: one line per column of the original (otherwise the page is one running paragraph).
    var keepColumns = false
    /// Corrections applied to every paragraph of text.
    var replacements: [ReplacementRule] = []
}

struct WordExportReport: Equatable {
    var pages = 0, pictures = 0, characters = 0, bytes = 0
    var summary: String {
        "已导出 \(pages) 页到 Word（\(characters) 字，\(pictures) 张页面图片，\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))）"
    }
}

/// Writes a .docx without any help from Word or AppKit's text system: a handful of XML parts and the page pictures.
enum WordExport {
    static let endings: Set<Character> = ["。", "！", "？", "…", "：", "；", "」", "』", "”", "’", ".", "!", "?", ":", ";", ")", "）", "》"]

    static func isCJK(_ character: Character) -> Bool { !(character.isASCII) && !character.isWhitespace }

    /// Text layer lines → paragraphs. Without merging, every line is a paragraph.
    static func paragraphs(from text: String, merge: Bool) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        var current = ""
        for line in lines {
            if line.isEmpty { if !current.isEmpty { result.append(current); current = "" }; continue }
            if !merge { result.append(line); continue }
            if current.isEmpty { current = line; continue }
            if let last = current.last, endings.contains(last) {
                result.append(current); current = line
            } else {
                let glue = (current.last.map { !isCJK($0) } ?? false) && (line.first.map { !isCJK($0) } ?? false) ? " " : ""
                current += glue + line
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\u{9}", "\u{A}", "\u{D}": result += " "
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF || (0xD800...0xDFFF).contains(scalar.value) { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func textParagraph(_ text: String, style: String? = nil, size: Int = 24, bold: Bool = false, gray: Bool = false, centered: Bool = false) -> String {
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if centered { properties += "<w:jc w:val=\"center\"/>" }
        if style == nil { properties += "<w:spacing w:after=\"120\" w:line=\"360\" w:lineRule=\"auto\"/>" }
        var run = "<w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"宋体\"/>"
        if bold { run += "<w:b/>" }
        if gray { run += "<w:color w:val=\"808080\"/>" }
        run += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
        return "<w:p><w:pPr>\(properties)</w:pPr><w:r><w:rPr>\(run)</w:rPr><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>"
    }

    private static func picture(id: Int, relationship: String, name: String, width: Int, height: Int) -> String {
        """
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(id)" name="\(name)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static let contentTypes = header + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
    """

    private static let rootRelationships = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """

    private static func headingStyle(_ level: Int, size: Int) -> String {
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"黑体\"/><w:b/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
    }

    private static let styles = header + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"宋体\"/><w:sz w:val=\"24\"/><w:szCs w:val=\"24\"/><w:lang w:val=\"en-US\" w:eastAsia=\"zh-CN\"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        + headingStyle(1, size: 36) + headingStyle(2, size: 32) + headingStyle(3, size: 28) + "</w:styles>"

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Writes the chosen pages of `document` as a Word file. `progress` runs on the calling thread.
    static func write(_ document: PDFDocument, pages: [Int], outline: [OutlineEntry], options: WordExportOptions, regions: [Int: [RecognizedLine]] = [:], to url: URL,
                      progress: (Double) -> Void = { _ in }) throws -> WordExportReport {
        var report = WordExportReport()
        let zip = try ZipWriter(url: url)
        do {
            var body = "", relationships = ""
            var pictureCount = 0
            try zip.add("[Content_Types].xml", Data(contentTypes.utf8))
            try zip.add("_rels/.rels", Data(rootRelationships.utf8))
            try zip.add("word/styles.xml", Data(styles.utf8))
            let maxWidth = 5_580_000.0, maxHeight = 7_200_000.0           // 15.5 cm x 20 cm in EMU
            for (offset, index) in pages.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let page = document.page(at: index) else { return }
                    for entry in outline where entry.page == index {
                        body += textParagraph(entry.label, style: "Heading\(min(entry.depth, 2) + 1)", size: 28, bold: true)
                    }
                    if options.pageMarks { body += textParagraph("—— 第 \(index + 1) 页 ——", size: 18, gray: true, centered: true) }
                    if options.content != .textOnly {
                        let image = try DocumentServices.render(page, maxDimension: options.imageSize.pixels)
                        if let data = jpeg(image, quality: options.imageSize.quality) {
                            pictureCount += 1
                            let id = pictureCount
                            let name = String(format: "page-%04d.jpg", index + 1)
                            let aspect = Double(image.height) / Double(max(image.width, 1))
                            var width = maxWidth, height = maxWidth * aspect
                            if height > maxHeight { height = maxHeight; width = maxHeight / max(aspect, 0.01) }
                            // Each picture goes straight into the file, so a book of hundreds of pages never holds them all in memory.
                            try zip.add("word/media/\(name)", data)
                            relationships += "<Relationship Id=\"rId\(id + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                            body += picture(id: id, relationship: "rId\(id + 1)", name: name, width: Int(width), height: Int(height))
                            report.pictures += 1
                        }
                    }
                    if options.content != .imagesOnly {
                        let found = OrderedText.paragraphs(regions: regions[index], pageText: page.string ?? "", mergeLines: options.mergeLines, keepColumns: options.keepColumns)
                        for paragraph in found.map({ ReplacementRules.apply(options.replacements, to: $0) }) {
                            body += textParagraph(paragraph)
                            report.characters += paragraph.filter { !$0.isWhitespace }.count
                        }
                    }
                    report.pages += 1
                }
                progress(Double(offset + 1) / Double(max(pages.count, 1)) * 0.9)
            }
            let documentXML = header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>"
                + body + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1417\" w:right=\"1417\" w:bottom=\"1417\" w:left=\"1417\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
            let documentRelationships = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" + relationships + "</Relationships>"
            try zip.add("word/document.xml", Data(documentXML.utf8))
            try zip.add("word/_rels/document.xml.rels", Data(documentRelationships.utf8))
            try zip.finish()
        } catch {
            zip.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        report.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        progress(1)
        return report
    }
}
