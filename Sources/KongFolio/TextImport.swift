import AppKit
import CoreText
import Foundation
import PDFKit

/// Opens plain text and Markdown by typesetting them into A4 PDF pages (宋体, 12 pt, 2.5 cm margins).
/// The workspace only knows PDF, so a text file becomes an ordinary document afterwards: its text is a real,
/// searchable text layer and annotations, excerpts and exports work as for any other PDF.
///
/// Markdown support is deliberately small: headings, bold, italic, inline code, links, bullet / numbered /
/// task lists, block quotes, fenced code and horizontal rules. Tables and images are not rendered; their
/// source text is kept as is. Every source line becomes its own paragraph (line breaks are never merged).
enum TextImport {
    static let plainExtensions: Set<String> = ["txt", "text"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    static let htmlExtensions: Set<String> = ["html", "htm"]
    static var extensions: Set<String> { plainExtensions.union(markdownExtensions).union(htmlExtensions) }
    static func handles(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static let pageSize = CGSize(width: 595.28, height: 841.89)   // A4
    static let margin: CGFloat = 70.87                             // 2.5 cm
    static let bodySize: CGFloat = 12
    static let maximumPages = 3000

    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let styleKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))

    // MARK: Entry points

    static func document(from url: URL) throws -> PDFDocument {
        let data = try Data(contentsOf: url)
        let text = try decode(data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolioError(message: "文本文件是空的。") }
        return try RichTextDocument(text, format: TextDocumentFormat.forURL(url), baseURL: url.deletingLastPathComponent()).pdf()
    }

    static func render(_ text: String, markdown isMarkdown: Bool) throws -> PDFDocument {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolioError(message: "文本文件是空的。") }
        return try pdf(from: isMarkdown ? markdown(text) : plainText(text))
    }

    // MARK: Decoding

    /// UTF-8 (with or without BOM) and UTF-16 with BOM first; then GB18030 and Big5 for legacy Chinese files.
    /// GB18030 accepts most Big5 byte pairs, so Big5 files may still decode as garbage; re-save them as UTF-8.
    static func decode(_ data: Data) throws -> String {
        var text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030) ?? String(data: data, encoding: big5)
        }
        guard let text else { throw FolioError(message: "无法识别文本编码（已尝试 UTF-8、UTF-16、GB18030、Big5）。请另存为 UTF-8 后再打开。") }
        return text
    }

    static func normalized(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        result.removeAll { $0 == "\u{FEFF}" || $0 == "\u{0C}" }
        return result
    }

    // MARK: Fonts and styles

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, monospace: Bool = false) -> CTFont {
        var font = CTFontCreateWithName((monospace ? "Menlo" : "Songti SC") as CFString, size, nil)
        if bold, let heavier = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) { font = heavier }
        if italic {
            // 宋体 has no italic face; slant the glyphs instead.
            var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            font = CTFontCreateCopyWithAttributes(font, size, &slant, nil)
        }
        return font
    }

    static func paragraphStyle(first: CGFloat = 0, indent: CGFloat = 0, after: CGFloat = 0, before: CGFloat = 0, lineHeight: CGFloat = 1.4) -> CTParagraphStyle {
        let values: [CGFloat] = [first, indent, after, before, lineHeight]
        return values.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            let size = MemoryLayout<CGFloat>.size
            let settings = [
                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: size, value: base),
                CTParagraphStyleSetting(spec: .headIndent, valueSize: size, value: base + 1),
                CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: base + 2),
                CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: size, value: base + 3),
                CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: size, value: base + 4),
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
    }

    static func plainText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: normalized(text), attributes: [fontKey: font(size: bodySize), styleKey: paragraphStyle()])
    }

    // MARK: Markdown

    static func markdown(_ text: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let gray = CGColor(gray: 0.35, alpha: 1)
        var inFence = false

        func append(_ content: NSAttributedString, _ style: CTParagraphStyle) {
            let block = NSMutableAttributedString(attributedString: content)
            block.append(NSAttributedString(string: "\n", attributes: [fontKey: font(size: bodySize)]))
            block.addAttribute(styleKey, value: style, range: NSRange(location: 0, length: block.length))
            output.append(block)
        }

        for raw in normalized(text).components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence {
                let code = NSAttributedString(string: raw, attributes: [fontKey: font(size: 10.5, monospace: true), colorKey: CGColor(gray: 0.2, alpha: 1)])
                append(code, paragraphStyle(first: 12, indent: 12, lineHeight: 1.25))
                continue
            }
            if trimmed.isEmpty { continue }

            let level = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), trimmed.dropFirst(level).first == " " {
                let sizes: [CGFloat] = [22, 18, 16, 14, 13, 12]
                let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                append(inline(title, size: sizes[level - 1], bold: true), paragraphStyle(after: 6, before: level <= 2 ? 12 : 8))
                continue
            }

            let stripped = trimmed.filter { $0 != " " }
            if stripped.count >= 3, let mark = stripped.first, "-*_".contains(mark), stripped.allSatisfy({ $0 == mark }) {
                let rule = NSAttributedString(string: String(repeating: "─", count: 36), attributes: [fontKey: font(size: bodySize), colorKey: gray])
                append(rule, paragraphStyle(after: 6, before: 6))
                continue
            }

            if trimmed.hasPrefix(">") {
                let quote = String(trimmed.drop(while: { $0 == ">" || $0 == " " }))
                append(inline(quote, size: bodySize, color: gray), paragraphStyle(first: 20, indent: 20, after: 4))
                continue
            }

            if let item = listItem(raw) {
                let offset = CGFloat(min(item.indent, 16)) * 8
                append(inline(item.marker + item.text, size: bodySize), paragraphStyle(first: 8 + offset, indent: 8 + offset + item.hanging, after: 2))
                continue
            }

            append(inline(trimmed, size: bodySize), paragraphStyle(after: 6))
        }
        return output
    }

    /// Recognises "- ", "* ", "+ ", "1. " and "1) " list lines, with optional task boxes.
    static func listItem(_ line: String) -> (indent: Int, marker: String, text: String, hanging: CGFloat)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = body.first else { return nil }
        if "-*+".contains(first), body.dropFirst().first == " " {
            var rest = String(body.dropFirst(2))
            var marker = "• "
            if rest.hasPrefix("[ ] ") { marker = "☐ "; rest = String(rest.dropFirst(4)) }
            else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { marker = "☑ "; rest = String(rest.dropFirst(4)) }
            return (indent, marker, rest, 14)
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let separator = after.first, separator == "." || separator == ")", after.dropFirst().first == " " {
                return (indent, "\(digits)\(separator) ", String(after.dropFirst(2)), 18)
            }
        }
        return nil
    }

    /// Converts inline Markdown (bold, italic, code, links) of one line into styled text.
    static func inline(_ source: String, size: CGFloat, bold: Bool = false, italic: Bool = false, color: CGColor? = nil) -> NSAttributedString {
        func attributes(bold: Bool, italic: Bool, code: Bool) -> [NSAttributedString.Key: Any] {
            var result: [NSAttributedString.Key: Any] = [fontKey: font(size: code ? size * 0.9 : size, bold: bold, italic: italic, monospace: code)]
            if let color { result[colorKey] = color }
            return result
        }
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: source, attributes: attributes(bold: bold, italic: italic, code: false))
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var style = attributes(bold: bold || intent.contains(.stronglyEmphasized), italic: italic || intent.contains(.emphasized), code: intent.contains(.code))
            if let link = run.link {
                style[.link] = link
                style[colorKey] = CGColor(red: 0.12, green: 0.36, blue: 0.85, alpha: 1)
                style[underlineKey] = NSNumber(value: CTUnderlineStyle.single.rawValue)
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: style))
        }
        return output
    }

    // MARK: Pagination

    static func pdf(from text: NSAttributedString) throws -> PDFDocument {
        let failure = FolioError(message: "文本排版失败。")
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard text.length > 0, let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw failure }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: box.insetBy(dx: margin, dy: margin), transform: nil)
        var location = 0, pages = 0
        while location < text.length {
            guard pages < maximumPages else { context.closePDF(); throw FolioError(message: "文本过长，超过 \(maximumPages) 页，请拆分后再打开。") }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            addLinks(in: frame, path: path, to: context)
            context.endPDFPage()
            pages += 1
            // A frame that shows nothing would loop forever; always move on by at least one character.
            location += max(CTFrameGetVisibleStringRange(frame).length, 1)
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount > 0 else { throw failure }
        return document
    }
    /// CoreText paints link text; PDF link annotations make it usable in the preview and exported file.
    static func addLinks(in frame: CTFrame, path: CGPath, to context: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let value = attributes[NSAttributedString.Key.link.rawValue],
                      let url = (value as? URL) ?? URL(string: String(describing: value)) else { continue }
                let range = CTRunGetStringRange(run)
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                let x = CTLineGetOffsetForStringIndex(line, range.location, nil)
                let rect = CGRect(x: path.boundingBox.minX + origins[index].x + x, y: path.boundingBox.minY + origins[index].y - descent, width: width, height: ascent + descent)
                context.setURL(url as CFURL, for: rect)
            }
        }
    }

}
