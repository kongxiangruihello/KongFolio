import AppKit
import PDFKit

struct PageBookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var page: Int
    var label: String
}
struct OutlineEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var page: Int
    var label: String
    var depth: Int
    var point: CGPoint?
}
struct ReadingState: Codable {
    var bookmarks: [PageBookmark] = []
    var outline: [OutlineEntry] = []
    var layout = ReadingLayout.continuous
    var point: CGPoint?
    var scale: Double?
    var bibliography: Bibliography? = nil
}
struct SearchHit: Identifiable {
    var id = UUID()
    var page: Int
    var range: NSRange
    var snippet: String
    /// The PDF page label (usually the printed page number) when it differs from the physical position.
    var label: String? = nil
    /// For a hit on a vertical page that is read from its recognition record: one box per column the match covers,
    /// as fractions of the page. `range` means nothing then.
    var strips: [CGRect]? = nil
}
struct AnnotationNote: Identifiable {
    var id: String { "\(page)-\(index)" }
    var page: Int
    var index: Int
    var kind: String
    var quote: String
    var note: String
    var label: String? = nil
    /// The marker colour name ("黄", "绿", "蓝", "粉") for coloured marks, and the colour itself for the sidebar swatch.
    var colorName: String? = nil
    var rgb: [Double]? = nil
    /// Labels the reader gave the entry in the notes outline editor.
    var tags: [String] = []
    /// "第 3 页" or "第 3 页（印刷页码 15）".
    var pageDescription: String { label.map { "第 \(page + 1) 页（印刷页码 \($0)）" } ?? "第 \(page + 1) 页" }
}

/// Text normalized for searching: line breaks inside CJK text are removed, other whitespace runs
/// become one space, case is folded and (optionally) traditional characters are mapped to simplified.
/// `origins` maps every UTF-16 unit of `text` back to a range in the original string.
struct FoldedText {
    var text: NSString
    var origins: [NSRange]

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
        default: return false
        }
    }

    init(_ original: String, simplify: Bool, cache: inout [String: String]) {
        let source = original as NSString
        var units: [unichar] = []
        var origins: [NSRange] = []
        var pendingSpace: NSRange?
        var previousCJK = false
        var location = 0
        while location < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: location)
            location = NSMaxRange(range)
            let piece = source.substring(with: range)
            if piece.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                if !units.isEmpty, pendingSpace == nil { pendingSpace = range }
                continue
            }
            let cjk = piece.precomposedStringWithCompatibilityMapping.unicodeScalars.first.map(FoldedText.isCJK) ?? false
            if let space = pendingSpace {
                if !(previousCJK && cjk) { units.append(0x20); origins.append(space) }
                pendingSpace = nil
            }
            // NFKC folds Kangxi radicals (⾃ → 自) that PDF text extraction sometimes returns, and full-width forms.
            var folded = piece.precomposedStringWithCompatibilityMapping.lowercased()
            if simplify && cjk {
                if let cached = cache[piece] { folded = cached }
                else {
                    let converted = folded.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? folded
                    folded = converted
                    cache[piece] = converted
                }
            }
            for unit in folded.utf16 { units.append(unit); origins.append(range) }
            previousCJK = cjk
        }
        text = NSString(characters: units, length: units.count)
        self.origins = origins
    }

    func originalRange(of folded: NSRange) -> NSRange {
        let first = origins[folded.location], last = origins[NSMaxRange(folded) - 1]
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
enum ReadingServices {
    static let quoteKey = PDFAnnotationKey(rawValue: "KongFolioQuote")
    static func outline(_ document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [OutlineEntry] = []
        func visit(_ node: PDFOutline, depth: Int) {
            guard depth < 32, result.count < 10000 else { return }
            if let destination = node.destination ?? (node.action as? PDFActionGoTo)?.destination, let page = destination.page {
                let index = document.index(for: page)
                if index != NSNotFound { result.append(OutlineEntry(page: index, label: node.label ?? "未命名章节", depth: depth, point: destination.point)) }
            }
            for i in 0..<node.numberOfChildren { if let child = node.child(at: i) { visit(child, depth: depth + 1) } }
        }
        for i in 0..<root.numberOfChildren { if let child = root.child(at: i) { visit(child, depth: 0) } }
        return result
    }
    static func applyOutline(_ entries: [OutlineEntry], to doc: PDFDocument) {
        // PDFKit can return the original backing bytes after only outlineRoot changes (macOS 27).
        // A reversible page-tree edit marks the document modified, preserving added/deleted outlines on save.
        defer {
            if !doc.isEncrypted || doc.allowsDocumentChanges, let first = doc.page(at: 0) {
                doc.removePage(at: 0); doc.insert(first, at: 0)
            }
        }
        guard !entries.isEmpty else { doc.outlineRoot = nil; return }
        let root = PDFOutline(); var stack: [(Int, PDFOutline)] = [(-1, root)]
        for entry in entries {
            guard let page = doc.page(at: entry.page) else { continue }
            while stack.count > 1 && stack.last!.0 >= entry.depth { stack.removeLast() }
            let node = PDFOutline(); node.label = entry.label
            node.destination = PDFDestination(page: page, at: entry.point ?? CGPoint(x: page.bounds(for: .cropBox).minX, y: page.bounds(for: .cropBox).maxY))
            let parent = stack.last!.1; parent.insertChild(node, at: parent.numberOfChildren); stack.append((entry.depth, node))
        }
        doc.outlineRoot = root
    }
    /// Finds `query` in `text`, ignoring line breaks inside CJK text, case and (optionally) 繁简 differences.
    /// Returned ranges refer to the original text, so PDFKit selections land on the right characters.
    static func matches(in text: String, query: String, simplify: Bool = true, cache: inout [String: String], limit: Int = Int.max) -> [NSRange] {
        let needle = FoldedText(query, simplify: simplify, cache: &cache).text
        guard needle.length > 0 else { return [] }
        let haystack = FoldedText(text, simplify: simplify, cache: &cache)
        var result: [NSRange] = []
        var start = 0
        while start < haystack.text.length && result.count < max(0,limit) {
            let found = haystack.text.range(of: needle as String, options: [.literal], range: NSRange(location: start, length: haystack.text.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(haystack.originalRange(of: found))
            start = NSMaxRange(found)
        }
        return result
    }

    static func search(_ data: Data, query: String, limit: Int = 1000, simplify: Bool = true, records: [Int: [RecognizedLine]] = [:]) throws -> [SearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let doc = PDFDocument(data: data) else { return [] }
        var hits: [SearchHit] = []
        var cache: [String: String] = [:]
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let label = pageLabel(page, index: i)
            // A vertical page that was recognised here is searched in reading order, so a phrase that runs from
            // the foot of one column to the head of the next is found (PDFKit would read the columns left to right).
            var recognised: [OrderedText.Glyph]?
            if let lines = records[i], let found = OrderedText.characters(lines), !found.isEmpty { recognised = found } else { recognised = OrderedText.glyphs(of: page) }
            if let characters = recognised {
                let joined = characters.map(\.text).joined()
                var starts: [Int] = []
                var offset = 0
                for character in characters { starts.append(offset); offset += character.text.utf16.count }
                for found in matches(in: joined, query: query, simplify: simplify, cache: &cache) {
                    guard let first = starts.firstIndex(of: found.location) else { continue }
                    let last = (starts.lastIndex { $0 < NSMaxRange(found) }) ?? first
                    var strips: [CGRect] = []
                    var current: Int?
                    for character in characters[first...max(first, last)] {
                        if character.column == current, let tail = strips.last { strips[strips.count - 1] = tail.union(character.box) }
                        else { strips.append(character.box); current = character.column }
                    }
                    let from = max(0, first - 8), to = min(characters.count, last + 16)
                    let snippet = characters[from..<to].map(\.text).joined()
                    hits.append(SearchHit(page: i, range: NSRange(location: 0, length: 0), snippet: repairIdeographs(snippet), label: label, strips: strips))
                    if hits.count >= limit { return hits }
                }
                continue
            }
            let string = page.string ?? ""
            let text = string as NSString
            for found in matches(in: string, query: query, simplify: simplify, cache: &cache) {
                let lower = max(0, found.location - 32), upper = min(text.length, NSMaxRange(found) + 64)
                let excerpt = text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))).replacingOccurrences(of: "\n", with: " ")
                hits.append(SearchHit(page: i, range: found, snippet: repairIdeographs(excerpt), label: label))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Text extracted from PDF text layers can contain Kangxi radicals (U+2F00…) or CJK radical
    /// supplements instead of the ordinary ideographs; map only those back, leaving full-width punctuation alone.
    static func repairIdeographs(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if (0x2E80...0x2FDF).contains(scalar.value), let mapped = String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars.first, mapped != scalar {
                output.append(mapped)
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// The page label when it carries information beyond the physical position (e.g. "xii" or "15" on page 27).
    static func pageLabel(_ page: PDFPage, index: Int) -> String? {
        guard let label = page.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty, label != String(index + 1) else { return nil }
        return label
    }

    static func bibliography(from document: PDFDocument) -> Bibliography {
        var result = Bibliography()
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { result.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { result.author = author.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }

    /// The name a kind of annotation goes by in lists and exports.
    static func kindName(for type: String?) -> String {
        switch type {
        case "Highlight": return "高亮"
        case "Underline": return "下划线"
        case "StrikeOut": return "删除线"
        case "Text": return "批注"
        case "FreeText": return "文字框"
        case "Ink": return "手写"
        case "Line": return "箭头/线条"
        case "Square": return "矩形"
        case "Circle": return "椭圆"
        default: return type ?? "标注"
        }
    }

    static func notes(_ doc: PDFDocument) -> [AnnotationNote] {
        var notes: [AnnotationNote] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for (index, annotation) in page.annotations.enumerated() {
                guard !["Link", "Widget", "Popup"].contains(annotation.type ?? "") else { continue }
                let kind = kindName(for: annotation.type)
                let markup = ["Highlight", "Underline", "StrikeOut"].contains(annotation.type ?? "")
                let quote = annotation.value(forAnnotationKey: quoteKey) as? String ?? (markup ? page.selection(for: annotation.bounds)?.string ?? "" : "")
                var entry = AnnotationNote(page: i, index: index, kind: kind, quote: repairIdeographs(quote), note: annotation.contents ?? "", label: pageLabel(page, index: i))
                if markup || annotation.type == "Text" || annotation.type == "Ink", let rgb = annotation.color.usingColorSpace(.sRGB) {
                    entry.colorName = MarkupColor.nearest(to: rgb)?.rawValue
                    entry.rgb = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
                }
                notes.append(entry)
            }
        }
        return notes
    }
    private static let markupNames: Set<String> = ["高亮", "下划线", "删除线"]
    static func markdown(title: String, notes: [AnnotationNote], bibliography: Bibliography? = nil) -> String {
        let title = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        var text = "# \(title) — 批注摘要\n\n"
        if let bibliography, !bibliography.isEmpty { text += "书目：\(bibliography.citation)  \n" }
        text += "来源文档：\(title)  \n"
        text += notes.contains { $0.label != nil }
            ? "“第 N 页”为文档中的物理页序；括号内为 PDF 页码标签，通常即书上的印刷页码，引用时请以印刷页码为准。\n"
            : "页码按文档当前物理页序编号（此 PDF 未提供不同的印刷页码标签）。\n"
        var current = -1
        for entry in notes.sorted(by: { ($0.page, $0.index) < ($1.page, $1.index) }) {
            if entry.page != current { current = entry.page; text += "\n## \(entry.pageDescription)\n" }
            var heading = entry.kind
            if markupNames.contains(entry.kind), let colour = entry.colorName { heading += "（\(colour)）" }
            text += "\n### \(heading)\n\n"
            if !entry.quote.isEmpty { text += entry.quote.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
            if !entry.note.isEmpty { text += "笔记：\n\n" + entry.note + "\n" }
            if entry.quote.isEmpty && entry.note.isEmpty { text += "（图形标注，无文本）\n" }
            let cited = entry.label ?? String(entry.page + 1)
            if let bibliography, !bibliography.isEmpty { text += "\n引用：\(bibliography.citation(page: cited))\n" }
            else { text += "\n来源页：\(entry.pageDescription.replacingOccurrences(of: "第 ", with: "").replacingOccurrences(of: " 页", with: ""))\n" }
        }
        return text
    }
}
extension Workspace {
    func addBookmark() {
        guard count > 0 else { return }; checkpoint()
        bookmarks.append(PageBookmark(page: selection, label: bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "第 \(selection + 1) 页" : bookmarkName))
        bookmarkName = ""; edited(pdfChanged: false); sidebarTab = .bookmarks
    }
    func deleteBookmark(_ id: UUID) { checkpoint(); bookmarks.removeAll { $0.id == id }; edited(pdfChanged: false) }
    func openOutline(_ entry: OutlineEntry) { selectPage(entry.page); readingPoint = entry.point; navigationToken = UUID() }
    func captureReadingPosition() {
        guard let view = pdfView, view.document === document, let destination = view.currentDestination, let page = destination.page, document.index(for: page) == selection else { return }
        let point = destination.point, scale = view.autoScales ? nil : Double(view.scaleFactor)
        guard point.x.isFinite, point.y.isFinite, readingPoint != point || readingScale != scale else { return }
        readingPoint = point; readingScale = scale
        scheduleRecovery()
    }
    /// What to select on the page for a search hit.
    func searchSelection(for hit: SearchHit) -> PDFSelection? {
        guard let page else { return nil }
        guard let strips = hit.strips else { return page.selection(for: hit.range) }
        let crop = page.bounds(for: .cropBox)
        var combined: PDFSelection?
        for strip in strips {
            guard let part = page.selection(for: OrderedText.pageRect(forFraction: strip, cropBox: crop, rotation: page.rotation)) else { continue }
            if let existing = combined { existing.add(part) } else { combined = part }
        }
        return combined
    }

    func startSearch() {
        searchTask?.cancel(); searchResults = []; searchMessage = ""; searchCursor = nil
        guard !search.isEmpty, let data = try? pdfData() else { return }
        let query = search, version = revision; searchMessage = "正在搜索…"; sidebarTab = .search
        var records: [Int: [RecognizedLine]] = [:]
        for index in 0..<count { if let lines = meta(index).ocrRegions, OrderedText.isVertical(lines) { records[index] = lines } }
        let job = Task.detached { [records] in try ReadingServices.search(data, query: query, records: records) }; searchTask = job
        Task {
            do { let hits = try await job.value; guard revision == version, query == search else { return }; searchResults = hits; searchMessage = hits.count == 1000 ? "显示前 1000 处匹配，请缩小搜索范围" : "找到 \(hits.count) 处匹配（忽略换行，简繁通查）" }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func goToSearch(_ hit: SearchHit) {
        searchCursor = searchResults.firstIndex { $0.id == hit.id }
        selectPage(hit.page)
        guard let selection = searchSelection(for: hit) else { return }
        if let page { let bounds = selection.bounds(for: page); readingPoint = CGPoint(x: bounds.minX, y: bounds.maxY + 20) }
        pdfView?.setCurrentSelection(selection, animate: true); pdfView?.go(to: selection)
    }
    /// Copies the selected text (or the page being read, when nothing is selected) in reading order. On a vertical page
    /// that was recognised here that means a line per column, right to left; PDFKit's own copy would read the columns
    /// left to right. Other selections are copied as PDFKit gives them.
    func copyInReadingOrder() {
        guard count > 0 else { return }
        func put(_ text: String, _ note: String) {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status = note
        }
        guard let chosen = pdfView?.currentSelection, !(chosen.string ?? "").isEmpty else {
            if let columns = OrderedText.verticalColumns(meta(selection).ocrRegions ?? []) {
                put(columns.map { ReadingServices.repairIdeographs($0) }.joined(separator: "\n"), "已复制本页文字（竖排，按列从右到左）")
            } else if let page, let glyphs = OrderedText.glyphs(of: page) {
                put(ReadingServices.repairIdeographs(OrderedText.text(of: glyphs) { _ in true }), "已复制本页文字（竖排文字层，按列从右到左）")
            } else {
                put(ReadingServices.repairIdeographs(page?.string ?? ""), "已复制本页文字")
            }
            return
        }
        var parts: [String] = []
        for page in chosen.pages.sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
            let index = document.index(for: page)
            guard index != NSNotFound, let glyphs = OrderedText.characters(meta(index).ocrRegions ?? []) ?? OrderedText.glyphs(of: page) else {
                put(ReadingServices.repairIdeographs(chosen.string ?? ""), "已复制（所选页没有竖排识别记录，按文字层顺序）")
                return
            }
            let ranges = (0..<chosen.numberOfTextRanges(on: page)).map { chosen.range(at: $0, on: page) }
            let crop = page.bounds(for: .cropBox)
            parts.append(OrderedText.text(of: glyphs) { glyph in
                let rect = OrderedText.pageRect(forFraction: glyph.box, cropBox: crop, rotation: page.rotation)
                let position = page.characterIndex(at: CGPoint(x: rect.midX, y: rect.midY))
                return position >= 0 && ranges.contains { NSLocationInRange(position, $0) }
            })
        }
        put(ReadingServices.repairIdeographs(parts.filter { !$0.isEmpty }.joined(separator: "\n\n")), "已复制（竖排，按列从右到左）")
    }

    func refreshNotes() {
        guard let data = try? pdfData() else { return }; let version = revision
        Task {
            let results = await Task.detached { () -> [AnnotationNote] in guard let doc = PDFDocument(data: data) else { return [] }; return ReadingServices.notes(doc) }.value
            if version == revision { annotationNotes = results; selectedNoteIDs.formIntersection(results.map(\.id)) }
        }
    }
    func goToNote(_ entry: AnnotationNote) {
        selectPage(entry.page); guard let page, entry.index < page.annotations.count else { return }
        readingPoint = CGPoint(x: page.annotations[entry.index].bounds.minX, y: page.annotations[entry.index].bounds.maxY + 20)
        selectAnnotation(page.annotations[entry.index]); tool = .edit; pdfView?.go(to: page.annotations[entry.index].bounds, on: page)
    }
}

@MainActor final class ThumbnailCache {
    private let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 32 * 1024 * 1024; images.countLimit = 160 }
    func image(for key: String) -> NSImage? { images.object(forKey: key as NSString) }
    func put(_ image: NSImage, key: String, cost: Int) { images.setObject(image, forKey: key as NSString, cost: cost) }
    func clear() { images.removeAllObjects() }
}
