import Foundation

struct SearchBodySpan: Codable {
    var visible: NSRange
    var source: NSRange
    var verbatim: Bool
}

/// Search visible text while keeping exact UTF-16 selections in the editable source.
struct TextSearchBody {
    var text = ""
    var spans: [SearchBodySpan] = []
    var lineStarts = [0]
    static func make(_ source: String, format: TextDocumentFormat, bodyOnly: Bool = true) -> Self {
        let raw = source as NSString
        var result = Self(), visibleLength = 0
        for (i, unit) in source.utf16.enumerated() where unit == 10 { result.lineStarts.append(i + 1) }
        func append(_ value: String, source range: NSRange, verbatim: Bool) {
            guard !value.isEmpty else { return }
            let start = visibleLength
            visibleLength += value.utf16.count
            result.text += value
            if verbatim, let last = result.spans.last, last.verbatim, NSMaxRange(last.source) == range.location {
                result.spans[result.spans.count - 1].visible.length += value.utf16.count
                result.spans[result.spans.count - 1].source.length += range.length
            } else { result.spans.append(SearchBodySpan(visible: NSRange(location: start, length: value.utf16.count), source: range, verbatim: verbatim)) }
        }
        guard bodyOnly, format != .plain else {
            append(source, source: NSRange(location: 0, length: raw.length), verbatim: true); return result
        }
        let pattern: String
        if format == .html {
            pattern = #"(?is)<!--.*?(?:-->|$)|<(script|style|head)\b[^>]*>.*?(?:</\1\s*>|$)|<(?:"[^"]*"|'[^']*'|[^'">])*>|&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]+);"#
        } else {
            pattern = #"(?m)^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|[0-9]+[.)]\s+)|^\s*(?:`{3,}|~{3,}).*$|^\s*\|?\s*:?-{3,}[-| :]*\s*$|!?\[([^\]\n]*)\]\((?:<[^>]*>|[^)\n]*)\)|\\[\\`*_{}\[\]()#+.!>~-]|\*{1,3}|_{1,3}|`{1,2}"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            append(source, source: NSRange(location: 0, length: raw.length), verbatim: true); return result
        }
        var position = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: raw.length)) {
            if match.range.location > position { let range = NSRange(location: position, length: match.range.location - position); append(raw.substring(with: range), source: range, verbatim: true) }
            let token = raw.substring(with: match.range)
            if format == .html {
                if token.hasPrefix("&") { append(HTMLRichParser.decode(token), source: match.range, verbatim: false) }
                else if token.range(of: #"^</?(?:p|div|br|h[1-6]|li|tr|section|article|blockquote)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { append("\n", source: match.range, verbatim: false) }
            } else if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let range = match.range(at: 1); append(raw.substring(with: range), source: range, verbatim: true)
            } else if token.hasPrefix("\\"), match.range.length >= 2 {
                let range = NSRange(location: match.range.location + 1, length: match.range.length - 1); append(raw.substring(with: range), source: range, verbatim: true)
            }
            position = NSMaxRange(match.range)
        }
        if position < raw.length { let range = NSRange(location: position, length: raw.length - position); append(raw.substring(with: range), source: range, verbatim: true) }
        return result
    }
    static func sourceRange(_ range: NSRange, spans: [SearchBodySpan]?) -> NSRange {
        guard let spans, !spans.isEmpty else { return range }
        var low = Int.max, high = 0
        for span in spans where NSIntersectionRange(span.visible, range).length > 0 {
            let intersection = NSIntersectionRange(span.visible, range)
            let first = span.verbatim ? span.source.location + intersection.location - span.visible.location : span.source.location
            let last = span.verbatim ? first + intersection.length : NSMaxRange(span.source)
            low = min(low, first); high = max(high, last)
        }
        return low == Int.max ? range : NSRange(location: low, length: high - low)
    }
    static func line(at offset: Int, starts: [Int]?) -> Int? {
        guard let starts else { return nil }
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] <= offset { low = mid + 1 } else { high = mid } }
        return max(1, low)
    }
    func page(format: TextDocumentFormat, bodyOnly: Bool) -> FolderSearchPage {
        FolderSearchPage(index: 0, text: text, label: nil, glyphs: nil, category: format.rawValue + (bodyOnly ? " 正文" : " 源码"), sourceSpans: spans, sourceLineStarts: lineStarts)
    }
}

enum SearchScope: String, Codable, CaseIterable, Identifiable {
    case combined = "文件夹与当前编辑", folder = "仅文件夹", current = "仅当前编辑和摘录"
    var id: String { rawValue }
    var usesFolder: Bool { self != .current }
    var usesLive: Bool { self != .folder }
}
