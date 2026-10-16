import AppKit
import PDFKit

/// A run of consecutive pages exported as one file.
struct ChapterPart: Equatable {
    var title: String
    var pages: Range<Int>
}

/// Splits a book into one PDF per chapter, using the PDF's own outline (table of contents).
enum ChapterSplit {
    static let frontMatterTitle = "前置页"

    /// Outline depths that exist in the document, shallowest first (0 = top level).
    static func depths(_ entries: [OutlineEntry], pageCount: Int) -> [Int] {
        Array(Set(entries.filter { (0..<pageCount).contains($0.page) }.map(\.depth))).sorted()
    }

    /// Chapters made from the outline entries up to `depth`. Entries on the same page start one chapter only
    /// (the first one in outline order); pages before the first entry become a front-matter part.
    static func parts(entries: [OutlineEntry], pageCount: Int, depth: Int) -> [ChapterPart] {
        var seen = Set<Int>()
        let starts = entries.enumerated()
            .filter { $0.element.depth <= depth && (0..<pageCount).contains($0.element.page) }
            .sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }
            .filter { seen.insert($0.element.page).inserted }
            .map(\.element)
        guard let first = starts.first else { return [] }
        var result: [ChapterPart] = []
        if first.page > 0 { result.append(ChapterPart(title: frontMatterTitle, pages: 0..<first.page)) }
        for (index, entry) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].page : pageCount
            result.append(ChapterPart(title: entry.label, pages: entry.page..<end))
        }
        return result
    }

    /// "03-第一章 绪论.pdf": numbered so the files sort in book order; characters that are unsafe in file names are replaced.
    static func fileName(index: Int, total: Int, title: String) -> String {
        let width = max(2, String(total).count)
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var clean = String(title.unicodeScalars.map { unsafe.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if clean.isEmpty { clean = "章节" }
        if clean.count > 60 { clean = String(clean.prefix(60)) }
        return String(format: "%0\(width)d", index) + "-" + clean + ".pdf"
    }
}

extension BackgroundJobs {
    /// Writes each part to a staging folder next to the destination and moves it into place at the end,
    /// so a cancelled or failed run never leaves a half-filled folder.
    static func splitChapters(_ spec: JobSpec, doc: PDFDocument, progress: @escaping @Sendable (Double) -> Void) throws -> JobResult {
        guard !spec.chapters.isEmpty, spec.chapters.allSatisfy({ $0.pages.lowerBound >= 0 && $0.pages.upperBound <= doc.pageCount && !$0.pages.isEmpty }) else {
            throw FolioError(message: "章节范围无效。")
        }
        let parent = try spec.destination.unwrap("未选择导出目录")
        let id = UUID().uuidString
        let staging = parent.appendingPathComponent(".KongFolio-\(id).partial", isDirectory: true)
        let folder = parent.appendingPathComponent("KongFolio-章节-\(id.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (offset, part) in spec.chapters.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let data = try DocumentServices.subset(doc, indexes: Array(part.pages)).dataRepresentation().unwrap("拆分失败")
                let name = ChapterSplit.fileName(index: offset + 1, total: spec.chapters.count, title: part.title)
                try data.write(to: staging.appendingPathComponent(name), options: .atomic)
            }
            progress(Double(offset + 1) / Double(spec.chapters.count))
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: folder)
        return JobResult(destination: folder, message: "已按章节拆分为 \(spec.chapters.count) 个文件")
    }
}

extension Workspace {
    /// Number of files a split at `depth` would produce, for the menu.
    func chapterCount(depth: Int) -> Int { ChapterSplit.parts(entries: outlineEntries, pageCount: count, depth: depth).count }

    func splitByChapters(depth: Int) {
        guard count > 0, !busy, checkDraftsForExport() else { return }
        let parts = ChapterSplit.parts(entries: outlineEntries, pageCount: count, depth: depth)
        guard !parts.isEmpty else { error = "此文档没有可用于拆分的目录。"; return }
        let preview = parts.prefix(8).map { "• \($0.title)（第 \($0.pages.lowerBound + 1)–\($0.pages.upperBound) 页）" }.joined(separator: "\n")
        let more = parts.count > 8 ? "\n……另有 \(parts.count - 8) 个" : ""
        guard confirm("按目录拆分为 \(parts.count) 个 PDF？", preview + more + "\n\n每个文件只含对应页面；目录、书签和页码标签不会带入。", action: "选择文件夹…") else { return }
        guard let source = try? pdfData() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        runJob(JobSpec(operation: .chapters, source: source, pages: Array(0..<count), destination: folder, revision: revision, chapters: parts))
    }
}
