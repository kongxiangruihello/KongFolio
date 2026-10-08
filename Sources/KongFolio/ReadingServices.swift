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
    var layout = "连续"
    var point: CGPoint?
    var scale: Double?
}
struct SearchHit: Identifiable {
    var id = UUID()
    var page: Int
    var range: NSRange
    var snippet: String
}
struct AnnotationNote: Identifiable {
    var id: String { "\(page)-\(index)" }
    var page: Int
    var index: Int
    var kind: String
    var quote: String
    var note: String
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
    static func search(_ data: Data, query: String, limit: Int = 1000) throws -> [SearchHit] {
        guard !query.isEmpty, let doc = PDFDocument(data: data) else { return [] }
        var hits: [SearchHit] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            let text = (doc.page(at: i)?.string ?? "") as NSString
            var start = 0
            while start < text.length {
                let found = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: text.length - start))
                guard found.location != NSNotFound else { break }
                let lower = max(0, found.location - 32), upper = min(text.length, NSMaxRange(found) + 64)
                let excerpt = text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))).replacingOccurrences(of: "\n", with: " ")
                hits.append(SearchHit(page: i, range: found, snippet: excerpt))
                if hits.count >= limit { return hits }
                start = NSMaxRange(found)
            }
        }
        return hits
    }
    static func notes(_ doc: PDFDocument) -> [AnnotationNote] {
        var notes: [AnnotationNote] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for (index, annotation) in page.annotations.enumerated() {
                guard !["Link", "Widget", "Popup"].contains(annotation.type ?? "") else { continue }
                let kind: String
                switch annotation.type { case "Highlight": kind = "高亮"; case "Text": kind = "批注"; case "FreeText": kind = "文字框"; case "Ink": kind = "手写"; case "Line": kind = "箭头/线条"; default: kind = annotation.type ?? "标注" }
                let quote = annotation.value(forAnnotationKey: quoteKey) as? String ?? (annotation.type == "Highlight" ? page.selection(for: annotation.bounds)?.string ?? "" : "")
                notes.append(AnnotationNote(page: i, index: index, kind: kind, quote: quote, note: annotation.contents ?? ""))
            }
        }
        return notes
    }
    static func markdown(title: String, notes: [AnnotationNote]) -> String {
        let title = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        var text = "# \(title) — 批注摘要\n\n来源文档：\(title)  \n页码按文档当前物理页序编号。\n"
        var current = -1
        for entry in notes.sorted(by: { ($0.page, $0.index) < ($1.page, $1.index) }) {
            if entry.page != current { current = entry.page; text += "\n## 第 \(current + 1) 页\n" }
            text += "\n### \(entry.kind)\n\n"
            if !entry.quote.isEmpty { text += entry.quote.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
            if !entry.note.isEmpty { text += "笔记：\n\n" + entry.note + "\n" }
            if entry.quote.isEmpty && entry.note.isEmpty { text += "（图形标注，无文本）\n" }
            text += "\n来源页：\(entry.page + 1)\n"
        }
        return text
    }
}
extension Workspace {
    func addBookmark() {
        guard count > 0 else { return }; checkpoint()
        bookmarks.append(PageBookmark(page: selection, label: bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "第 \(selection + 1) 页" : bookmarkName))
        bookmarkName = ""; edited(); sidebarTab = "书签"
    }
    func deleteBookmark(_ id: UUID) { checkpoint(); bookmarks.removeAll { $0.id == id }; edited() }
    func openOutline(_ entry: OutlineEntry) { selectPage(entry.page); readingPoint = entry.point; navigationToken = UUID() }
    func captureReadingPosition() {
        guard let view = pdfView, view.document === document, let destination = view.currentDestination, let page = destination.page, document.index(for: page) == selection else { return }
        let point = destination.point, scale = view.autoScales ? nil : Double(view.scaleFactor)
        guard point.x.isFinite, point.y.isFinite, readingPoint != point || readingScale != scale else { return }
        readingPoint = point; readingScale = scale
        scheduleRecovery()
    }
    func startSearch() {
        searchTask?.cancel(); searchResults = []; searchMessage = ""
        guard !search.isEmpty, let data = try? pdfData() else { return }
        let query = search, version = revision; searchMessage = "正在搜索…"; sidebarTab = "搜索"
        let job = Task.detached { try ReadingServices.search(data, query: query) }; searchTask = job
        Task {
            do { let hits = try await job.value; guard revision == version, query == search else { return }; searchResults = hits; searchMessage = hits.count == 1000 ? "显示前 1000 处匹配，请缩小搜索范围" : "找到 \(hits.count) 处匹配" }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func goToSearch(_ hit: SearchHit) {
        selectPage(hit.page)
        guard let selection = page?.selection(for: hit.range) else { return }
        if let page { let bounds = selection.bounds(for: page); readingPoint = CGPoint(x: bounds.minX, y: bounds.maxY + 20) }
        pdfView?.setCurrentSelection(selection, animate: true); pdfView?.go(to: selection)
    }
    func refreshNotes() {
        guard let data = try? pdfData() else { return }; let version = revision
        Task {
            let results = await Task.detached { () -> [AnnotationNote] in guard let doc = PDFDocument(data: data) else { return [] }; return ReadingServices.notes(doc) }.value
            if version == revision { annotationNotes = results }
        }
    }
    func goToNote(_ entry: AnnotationNote) {
        selectPage(entry.page); guard let page, entry.index < page.annotations.count else { return }
        readingPoint = CGPoint(x: page.annotations[entry.index].bounds.minX, y: page.annotations[entry.index].bounds.maxY + 20)
        selectAnnotation(page.annotations[entry.index]); tool = "编辑标注"; pdfView?.go(to: page.annotations[entry.index].bounds, on: page)
    }
    func exportNotes() {
        guard let url = saveURL(type: .init(filenameExtension: "md") ?? .plainText, suffix: "md", name: title + "-notes") else { return }
        report { try ReadingServices.markdown(title: title, notes: ReadingServices.notes(document)).write(to: url, atomically: true, encoding: .utf8); status = "已导出带页码和原文的批注摘要" }
    }
}

@MainActor final class ThumbnailCache {
    private let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 32 * 1024 * 1024; images.countLimit = 160 }
    func image(for key: String) -> NSImage? { images.object(forKey: key as NSString) }
    func put(_ image: NSImage, key: String, cost: Int) { images.setObject(image, forKey: key as NSString, cost: cost) }
    func clear() { images.removeAllObjects() }
}
