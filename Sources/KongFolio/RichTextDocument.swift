import AppKit
import CoreText
import PDFKit

struct TextLayoutOptions: Codable, Equatable {
    static let key = "KongFolio.textLayout"
    var fontName = "Songti SC"
    var fontSize: Double = 12
    var lineHeight: Double = 1.4
    var margin: Double = 70.87
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return Self() }
        return value
    }
    var valid: Bool { fontSize.isFinite && (8...36).contains(fontSize) && lineHeight.isFinite && (1...2.5).contains(lineHeight) && margin.isFinite && (20...120).contains(margin) }
    func save() { if valid, let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }
}

enum RichBlock {
    case paragraph(NSAttributedString, heading: Int)
    case table([[NSAttributedString]])
    case image(Data, alt: String)
}

struct RichTextDocument {
    var blocks: [RichBlock]
    var options: TextLayoutOptions
    init(_ text: String, format: TextDocumentFormat, baseURL: URL? = nil, options: TextLayoutOptions = TextLayoutOptions()) throws {
        guard options.valid else { throw FolioError(message: "排版设置无效") }
        self.options = options
        switch format {
        case .plain: blocks = try TextImport.normalized(text).components(separatedBy: "\n").map { line in try Task.checkCancellation(); return .paragraph(Self.styled(line.isEmpty ? " " : line, options: options, markdown: false), heading: 0) }
        case .markdown: blocks = try Self.markdown(text, baseURL: baseURL, options: options)
        case .html: blocks = try HTMLRichParser.parse(text, baseURL: baseURL, options: options)
        }
    }
    static func styled(_ source: String, options: TextLayoutOptions, heading: Int = 0, markdown: Bool = true, bold: Bool = false) -> NSAttributedString {
        let size = CGFloat(options.fontSize) * ([1: 1.83, 2: 1.5, 3: 1.33, 4: 1.17][heading] ?? 1)
        let original = markdown ? TextImport.inline(source, size: size, bold: bold || heading > 0) : NSAttributedString(string: source, attributes: [TextImport.fontKey: TextImport.font(size: size)])
        let result = NSMutableAttributedString(attributedString: original)
        original.enumerateAttribute(TextImport.fontKey, in: NSRange(location: 0, length: original.length)) { value, range, _ in
            var font = CTFontCreateWithName(options.fontName as CFString, size, nil)
            if let value {
                let traits = CTFontGetSymbolicTraits(value as! CTFont)
                if traits.contains(.boldTrait) || bold || heading > 0 { font = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) ?? font }
                if traits.contains(.italicTrait) || abs(CTFontGetMatrix(value as! CTFont).c) > 0.01 {
                    var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                    font = CTFontCreateCopyWithAttributes(font, size, &matrix, nil)
                }
            }
            result.addAttribute(TextImport.fontKey, value: font, range: range)
        }
        result.addAttribute(TextImport.styleKey, value: TextImport.paragraphStyle(lineHeight: options.lineHeight), range: NSRange(location: 0, length: result.length))
        return result
    }
    static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
        var cells: [String] = [], current = "", escaped = false, code = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces)); return cells
    }
    static func markdown(_ text: String, baseURL: URL?, options: TextLayoutOptions) throws -> [RichBlock] {
        let lines = TextImport.normalized(text).components(separatedBy: "\n")
        var blocks: [RichBlock] = [], index = 0, fence: String?
        let images = try NSRegularExpression(pattern: #"!\[([^\]]*)\]\((<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)"#)
        while index < lines.count {
            try Task.checkCancellation()
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces); index += 1
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3)); if fence == nil { fence = marker } else if fence == marker { fence = nil }; continue
            }
            if fence != nil { blocks.append(.paragraph(styled(line.isEmpty ? " " : line, options: options, markdown: false), heading: 0)); continue }
            if trimmed.isEmpty { continue }
            if index < lines.count, line.contains("|") {
                let divider = tableCells(lines[index])
                if !divider.isEmpty && divider.allSatisfy({ $0.contains("-") && $0.allSatisfy { "-: ".contains($0) } }) {
                    var rows = [tableCells(line)]; index += 1
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(tableCells(lines[index])); index += 1 }
                    let columns = max(1, rows.map(\.count).max() ?? 1)
                    let content = rows.enumerated().map { row, cells in (0..<columns).map { styled($0 < cells.count ? cells[$0] : "", options: options, bold: row == 0) } }
                    blocks.append(.table(content)); continue
                }
            }
            let matches = images.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            if !matches.isEmpty {
                var position = 0
                for match in matches {
                    let raw = line as NSString
                    if match.range.location > position { blocks.append(.paragraph(styled(raw.substring(with: NSRange(location: position, length: match.range.location - position)), options: options), heading: 0)) }
                    let reference = raw.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    blocks.append(.image(try TextMedia.read(reference, baseURL: baseURL), alt: raw.substring(with: match.range(at: 1))))
                    position = NSMaxRange(match.range)
                }
                if position < (line as NSString).length { blocks.append(.paragraph(styled((line as NSString).substring(from: position), options: options), heading: 0)) }
                continue
            }
            let heading = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(heading), trimmed.dropFirst(heading).first == " " { blocks.append(.paragraph(styled(String(trimmed.dropFirst(heading + 1)), options: options, heading: heading), heading: heading)); continue }
            let attributed = TextImport.markdown(line)
            let source = attributed.string.trimmingCharacters(in: .newlines)
            if source != trimmed && (trimmed.hasPrefix(">") || TextImport.listItem(line) != nil) {
                let prefix = trimmed.hasPrefix(">") ? "❝ " : (TextImport.listItem(line)?.marker ?? "")
                let value = trimmed.hasPrefix(">") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : (TextImport.listItem(line)?.text ?? trimmed)
                blocks.append(.paragraph(styled(prefix + value, options: options), heading: 0))
            } else { blocks.append(.paragraph(styled(trimmed, options: options), heading: 0)) }
        }
        return blocks
    }
    func pdf() throws -> PDFDocument { try RichTextPDF.render(self) }
}

/// Local images and embedded data only; a document cannot trigger network requests during preview.
enum TextMedia {
    static func resolve(_ reference: String, baseURL: URL?) -> URL? {
        let value = reference.removingPercentEncoding ?? reference
        if let url = URL(string: reference), url.isFileURL { return url }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        guard URL(string: reference)?.scheme == nil, let baseURL else { return nil }
        return baseURL.appendingPathComponent(value).standardizedFileURL
    }
    static func read(_ reference: String, baseURL: URL?) throws -> Data {
        let data: Data
        if reference.hasPrefix("data:image/"), let comma = reference.firstIndex(of: ","), reference[..<comma].hasSuffix(";base64"),
           let decoded = Data(base64Encoded: String(reference[reference.index(after: comma)...])) { data = decoded }
        else {
            guard let url = resolve(reference, baseURL: baseURL) else { throw FolioError(message: "图片无法读取：\(reference.prefix(100))。请插入本地图片。") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 40 * 1024 * 1024 else { throw FolioError(message: "图片过大，请使用 40 MB 以内的图片") }
            data = try Data(contentsOf: url)
        }
        guard data.count <= 40 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw FolioError(message: "图片格式不支持或已损坏") }
        // Normalize orientation, dimensions and format for PDF and Word using the same pixels.
        let image = try CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 3200] as CFDictionary).unwrap("无法解码图片")
        return try SignatureImage.pngData(image).unwrap("无法转换图片")
    }
}
