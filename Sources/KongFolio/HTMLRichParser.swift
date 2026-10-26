import Foundation

/// Small, offline HTML reader. It retains document structure and inline styling without running scripts or loading CSS/resources.
enum HTMLRichParser {
    final class Node {
        var tag: String; var attributes: [String: String]; var text: String; var children: [Node] = []
        init(_ tag: String, attributes: [String: String] = [:], text: String = "") { self.tag = tag; self.attributes = attributes; self.text = text }
        var plain: String { text + children.map(\.plain).joined() }
    }
    static func decode(_ text: String) -> String {
        var result = text
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&"]
        for (from, to) in entities { result = result.replacingOccurrences(of: from, with: to) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).reversed() {
                let raw = (result as NSString).substring(with: match.range(at: 1))
                let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: result) { result.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return result
    }
    static func attributes(_ source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [:] }
        let text = source as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let value = (2...4).first { match.range(at: $0).location != NSNotFound }!
            result[text.substring(with: match.range(at: 1)).lowercased()] = decode(text.substring(with: match.range(at: value)))
        }
        return result
    }
    static func tree(_ source: String) throws -> Node {
        var html = source
        for pattern in ["(?is)<!--.*?-->", "(?is)<(script|style|head|iframe|object)\\b[^>]*>.*?</\\1\\s*>"] {
            html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let regex = try NSRegularExpression(pattern: "<[^>]+>|[^<]+")
        let root = Node("root"); var stack = [root]
        let voids: Set<String> = ["img", "br", "hr", "meta", "link", "input", "source", "wbr"]
        for match in regex.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)) {
            let token = (html as NSString).substring(with: match.range)
            guard token.hasPrefix("<") else { stack.last?.children.append(Node("#text", text: decode(token))); continue }
            let inner = token.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }
            if inner.hasPrefix("/") {
                let tag = inner.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 { stack.removeSubrange(index...) }
                continue
            }
            let tag = String(inner.prefix(while: { !$0.isWhitespace && $0 != "/" })).lowercased()
            guard !tag.isEmpty else { continue }
            if tag == "tr", stack.last?.tag == "tr" { stack.removeLast() }
            if ["td", "th"].contains(tag), ["td", "th"].contains(stack.last?.tag ?? "") { stack.removeLast() }
            let node = Node(tag, attributes: attributes(String(inner.dropFirst(tag.count))))
            stack.last?.children.append(node)
            if !voids.contains(tag), !inner.hasSuffix("/") {
                guard stack.count < 128 else { throw FolioError(message: "HTML 嵌套层数过多") }
                stack.append(node)
            }
        }
        return root
    }
    static func inline(_ node: Node) -> String {
        if node.tag == "#text" { return node.text.replacingOccurrences(of: "[\\s\\n\\r]+", with: " ", options: .regularExpression) }
        let value = node.children.map(inline).joined()
        switch node.tag {
        case "strong", "b", "th": return "**" + value + "**"
        case "em", "i": return "*" + value + "*"
        case "code": return "`" + value + "`"
        case "a": return node.attributes["href"].map { "[" + value + "](" + $0 + ")" } ?? value
        case "br": return "\n"
        default: return value
        }
    }
    static func descendants(_ node: Node, tags: Set<String>) -> [Node] {
        node.children.flatMap { tags.contains($0.tag) ? [$0] : descendants($0, tags: tags) }
    }
    static func parse(_ source: String, baseURL: URL?, options: TextLayoutOptions) throws -> [RichBlock] {
        let root = try tree(source)
        var result: [RichBlock] = []
        let blockTags: Set<String> = ["html", "body", "p", "div", "section", "article", "main", "header", "footer", "ul", "ol", "li", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "table", "img", "hr"]
        func walk(_ node: Node, heading: Int = 0) throws {
            if node.tag == "img" {
                if let reference = node.attributes["src"] { result.append(.image(try TextMedia.read(reference, baseURL: baseURL), alt: node.attributes["alt"] ?? "图片")) }; return
            }
            if node.tag == "table" {
                let rows = descendants(node, tags: ["tr"]).map { row in descendants(row, tags: ["td", "th"]).map { RichTextDocument.styled(inline($0), options: options, bold: $0.tag == "th") } }.filter { !$0.isEmpty }
                if !rows.isEmpty { result.append(.table(rows)) }; return
            }
            if node.tag == "pre" { result.append(.paragraph(RichTextDocument.styled(node.plain, options: options, markdown: false), heading: 0)); return }
            let level = node.tag.hasPrefix("h") ? Int(node.tag.dropFirst()) ?? heading : heading
            var pending = ""
            func flush() {
                let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.append(.paragraph(RichTextDocument.styled((node.tag == "li" ? "• " : "") + value, options: options, heading: level), heading: level)) }
                pending = ""
            }
            for child in node.children {
                if blockTags.contains(child.tag) { flush(); try walk(child, heading: level) }
                else if !descendants(child, tags: ["img", "table"]).isEmpty { flush(); try walk(child, heading: level) }
                else { pending += inline(child) }
            }
            flush()
        }
        try walk(root); return result
    }
}
