import AppKit
import CoreText
import Foundation
import PDFKit

/// Opens Word (.docx, .doc), OpenDocument (.odt), RTF / RTFD and HTML files by typesetting their text into A4
/// pages through `TextImport`, so they become ordinary searchable PDF documents.
///
/// What is kept: text, bold / italic / underline, font size (limited to 6–48 pt), text colour, alignment,
/// indents, paragraph spacing, lists and tables (as tab-separated rows), links (as blue underlined text).
/// What is not: pictures (replaced by a "［图片］" marker), headers and footers, page layout, comments and
/// tracked changes. Fonts are replaced by 宋体 (等宽字体 stays monospaced), as for text files.
enum RichTextImport {
    static let wordExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]
    static let htmlExtensions: Set<String> = ["html", "htm"]
    static var extensions: Set<String> { wordExtensions.union(htmlExtensions) }
    static func handles(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static let placeholder = "［图片］"
    private static var fontKey: NSAttributedString.Key { TextImport.fontKey }
    private static var colorKey: NSAttributedString.Key { TextImport.colorKey }
    private static var styleKey: NSAttributedString.Key { TextImport.styleKey }
    private static var underlineKey: NSAttributedString.Key { TextImport.underlineKey }

    // MARK: Entry points

    static func document(from url: URL) throws -> PDFDocument {
        let ext = url.pathExtension.lowercased()
        let text: NSAttributedString
        if htmlExtensions.contains(ext) {
            text = try html(Data(contentsOf: url))
        } else {
            do {
                text = normalize(try NSAttributedString(url: url, options: [:], documentAttributes: nil))
            } catch {
                throw FolioError(message: "无法读取“\(url.lastPathComponent)”：文件可能已损坏，或不是有效的文档。")
            }
        }
        guard text.string.contains(where: { !$0.isWhitespace && $0 != "\u{FFFC}" }) else {
            throw FolioError(message: "“\(url.lastPathComponent)”里没有可读取的文字。")
        }
        return try TextImport.pdf(from: text)
    }

    // MARK: Word processor documents

    /// Rewrites text read by AppKit into the typesetting attributes of `TextImport`.
    static func normalize(_ source: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let whole = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            var string = source.attributedSubstring(from: range).string
            string = string.replacingOccurrences(of: "\u{FFFC}", with: placeholder)
            string.removeAll { $0 == "\u{FEFF}" || $0 == "\u{0C}" || $0 == "\u{200B}" }
            guard !string.isEmpty else { return }

            var style: [NSAttributedString.Key: Any] = [:]
            let nsFont = attributes[.font] as? NSFont
            let traits = nsFont?.fontDescriptor.symbolicTraits ?? []
            let size = min(max(nsFont?.pointSize ?? TextImport.bodySize, 6), 48)
            style[fontKey] = TextImport.font(size: size, bold: traits.contains(.bold), italic: traits.contains(.italic), monospace: traits.contains(.monoSpace))
            if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), color.alphaComponent > 0.05 {
                // Text that would vanish on white paper is printed in black.
                let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                if luminance < 0.85 { style[colorKey] = color.cgColor }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                style[underlineKey] = NSNumber(value: CTUnderlineStyle.single.rawValue)
            }
            if attributes[.link] != nil {
                style[colorKey] = CGColor(red: 0.12, green: 0.36, blue: 0.85, alpha: 1)
                style[underlineKey] = NSNumber(value: CTUnderlineStyle.single.rawValue)
            }
            style[styleKey] = paragraphStyle(attributes[.paragraphStyle] as? NSParagraphStyle)
            output.append(NSAttributedString(string: string, attributes: style))
        }
        return output
    }

    private static func paragraphStyle(_ source: NSParagraphStyle?) -> CTParagraphStyle {
        let limit = TextImport.pageSize.width - 2 * TextImport.margin
        func clamp(_ value: CGFloat?, _ maximum: CGFloat) -> CGFloat { min(max(value ?? 0, 0), maximum) }
        var first = clamp(source?.firstLineHeadIndent, limit / 2)
        var head = clamp(source?.headIndent, limit / 2)
        var after = clamp(source?.paragraphSpacing, 36)
        var before = clamp(source?.paragraphSpacingBefore, 36)
        var multiple: CGFloat = {
            let value = source?.lineHeightMultiple ?? 0
            return value > 0.5 ? min(value, 3) : 1.3
        }()
        var alignment: CTTextAlignment = {
            switch source?.alignment {
            case .right: return .right
            case .center: return .center
            case .justified: return .justified
            default: return .left
            }
        }()
        return withUnsafePointer(to: &first) { f in
            withUnsafePointer(to: &head) { h in
                withUnsafePointer(to: &after) { a in
                    withUnsafePointer(to: &before) { b in
                        withUnsafePointer(to: &multiple) { m in
                            withUnsafePointer(to: &alignment) { al in
                                let size = MemoryLayout<CGFloat>.size
                                let settings = [
                                    CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: size, value: f),
                                    CTParagraphStyleSetting(spec: .headIndent, valueSize: size, value: h),
                                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: a),
                                    CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: size, value: b),
                                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: size, value: m),
                                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: al),
                                ]
                                return CTParagraphStyleCreate(settings, settings.count)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: HTML

    /// HTML is parsed with libxml's tolerant HTML reader instead of WebKit: it needs no web view, never loads
    /// anything from the network and behaves the same on every machine.
    static func html(_ data: Data) throws -> NSAttributedString {
        let source = try TextImport.decode(data)
        guard let document = try? XMLDocument(xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]),
              let root = document.rootElement() else {
            throw FolioError(message: "无法解析这个 HTML 文件。")
        }
        var builder = HTMLBuilder()
        builder.walk(root, style: .init())
        return builder.output
    }

    private struct HTMLStyle {
        var size: CGFloat = TextImport.bodySize
        var bold = false, italic = false, mono = false, underline = false, preformatted = false
        var color: CGColor?
        var indent: CGFloat = 0
    }

    private struct HTMLBuilder {
        let output = NSMutableAttributedString()
        private var listCounters: [Int] = []   // 0 = bullet list, n > 0 = ordered list at item n

        private static let skipped: Set<String> = ["head", "script", "style", "noscript", "svg", "template", "title", "select", "button", "iframe"]

        mutating func walk(_ node: XMLNode, style: HTMLStyle) {
            switch node.kind {
            case .text:
                appendText(node.stringValue ?? "", style)
            case .element:
                guard let element = node as? XMLElement, let name = element.name?.lowercased() else { return }
                visit(element, name, style)
            default:
                break
            }
        }

        private mutating func children(_ element: XMLElement, _ style: HTMLStyle) {
            for child in element.children ?? [] { walk(child, style: style) }
        }

        private mutating func visit(_ element: XMLElement, _ name: String, _ style: HTMLStyle) {
            if Self.skipped.contains(name) { return }
            var style = style
            switch name {
            case "br":
                output.append(NSAttributedString(string: "\n", attributes: [TextImport.fontKey: TextImport.font(size: style.size)]))
            case "hr":
                block(style, after: 6, before: 6) {
                    $0.output.append(NSAttributedString(string: String(repeating: "─", count: 36), attributes: [TextImport.fontKey: TextImport.font(size: TextImport.bodySize), TextImport.colorKey: CGColor(gray: 0.5, alpha: 1)]))
                }
            case "img":
                let alt = element.attribute(forName: "alt")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                appendText(alt.isEmpty ? RichTextImport.placeholder : "［图片：\(alt)］", style, collapse: false)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(name.dropFirst()) ?? 1
                style.size = [22, 18, 16, 14, 13, 12][level - 1]
                style.bold = true
                block(style, after: 6, before: level <= 2 ? 12 : 8) { $0.children(element, style) }
            case "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure", "figcaption", "form", "fieldset", "address", "dl", "dt", "details", "summary", "caption":
                block(style, after: name == "p" ? 6 : 0) { $0.children(element, style) }
            case "dd":
                style.indent += 24
                block(style, after: 2) { $0.children(element, style) }
            case "blockquote":
                style.indent += 20
                style.color = CGColor(gray: 0.35, alpha: 1)
                block(style, after: 4) { $0.children(element, style) }
            case "pre":
                style.mono = true
                style.preformatted = true
                style.size = 10.5
                block(style, after: 6) { $0.children(element, style) }
            case "ul", "ol":
                listCounters.append(name == "ol" ? 1 : 0)
                style.indent += 20
                children(element, style)
                listCounters.removeLast()
                if listCounters.isEmpty { ensureLineBreak() }
            case "li":
                var marker = "• "
                if let counter = listCounters.last, counter > 0 {
                    marker = "\(counter). "
                    listCounters[listCounters.count - 1] = counter + 1
                }
                block(style, after: 2, hanging: 14, first: -14) {
                    $0.appendText(marker, style, collapse: false)
                    $0.children(element, style)
                }
            case "table", "thead", "tbody", "tfoot":
                children(element, style)
                if name == "table" { ensureLineBreak() }
            case "tr":
                block(style, after: 2) { builder in
                    var first = true
                    for cell in element.children ?? [] {
                        guard let cell = cell as? XMLElement, ["td", "th"].contains(cell.name?.lowercased() ?? "") else { continue }
                        if !first { builder.appendText("\t", style, collapse: false) }
                        first = false
                        var cellStyle = style
                        if cell.name?.lowercased() == "th" { cellStyle.bold = true }
                        builder.children(cell, cellStyle)
                    }
                }
            case "strong", "b", "th":
                style.bold = true
                children(element, style)
            case "em", "i", "cite", "dfn", "var":
                style.italic = true
                children(element, style)
            case "u", "ins":
                style.underline = true
                children(element, style)
            case "code", "kbd", "samp", "tt":
                style.mono = true
                style.size = max(style.size * 0.9, 6)
                children(element, style)
            case "small":
                style.size = max(style.size * 0.85, 6)
                children(element, style)
            case "a":
                if element.attribute(forName: "href") != nil {
                    style.color = CGColor(red: 0.12, green: 0.36, blue: 0.85, alpha: 1)
                    style.underline = true
                }
                children(element, style)
            default:
                children(element, style)
            }
        }

        private mutating func block(_ style: HTMLStyle, after: CGFloat, before: CGFloat = 0, hanging: CGFloat = 0, first: CGFloat = 0, _ content: (inout HTMLBuilder) -> Void) {
            ensureLineBreak()
            let start = output.length
            content(&self)
            guard output.length > start else { return }
            if !output.string.hasSuffix("\n") { output.append(NSAttributedString(string: "\n", attributes: [TextImport.fontKey: TextImport.font(size: style.size)])) }
            let range = NSRange(location: start, length: output.length - start)
            let paragraph = TextImport.paragraphStyle(first: style.indent + hanging + first, indent: style.indent + hanging, after: after, before: before)
            // Inner blocks were styled first and keep their own paragraph style.
            output.enumerateAttribute(TextImport.styleKey, in: range) { value, subrange, _ in
                if value == nil { output.addAttribute(TextImport.styleKey, value: paragraph, range: subrange) }
            }
        }

        private mutating func ensureLineBreak() {
            if output.length > 0, !output.string.hasSuffix("\n") {
                output.append(NSAttributedString(string: "\n", attributes: [TextImport.fontKey: TextImport.font(size: TextImport.bodySize)]))
            }
        }

        private mutating func appendText(_ raw: String, _ style: HTMLStyle, collapse: Bool = true) {
            var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if collapse && !style.preformatted {
                var squeezed = ""
                var lastWasSpace = output.string.hasSuffix("\n") || output.length == 0 || output.string.hasSuffix(" ")
                for character in text {
                    if character == " " || character == "\n" || character == "\t" {
                        if !lastWasSpace { squeezed.append(" ") }
                        lastWasSpace = true
                    } else {
                        squeezed.append(character)
                        lastWasSpace = false
                    }
                }
                text = squeezed
            }
            text.removeAll { $0 == "\u{FEFF}" || $0 == "\u{0C}" }
            guard !text.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [TextImport.fontKey: TextImport.font(size: style.size, bold: style.bold, italic: style.italic, monospace: style.mono)]
            if let color = style.color { attributes[TextImport.colorKey] = color }
            if style.underline { attributes[TextImport.underlineKey] = NSNumber(value: CTUnderlineStyle.single.rawValue) }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
    }
}
