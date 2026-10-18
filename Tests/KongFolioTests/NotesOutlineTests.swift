import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class NotesOutlineTests: XCTestCase {
    func note(_ page: Int, _ index: Int = 0, kind: String = "高亮", quote: String = "", text: String = "", color: String? = "黄") -> AnnotationNote {
        AnnotationNote(page: page, index: index, kind: kind, quote: quote, note: text, label: nil, colorName: color, rgb: nil)
    }

    let outline = [
        OutlineEntry(page: 2, label: "第一卷", depth: 0),
        OutlineEntry(page: 3, label: "第一章", depth: 1),
        OutlineEntry(page: 6, label: "第二章", depth: 1),
        OutlineEntry(page: 9, label: "第二卷", depth: 0),
    ]

    func testNotesFallUnderTheChapterTheyAreIn() {
        let notes = [note(3, quote: "甲"), note(4, 1, quote: "乙"), note(7, quote: "丙"), note(10, quote: "丁")]
        let sections = NotesOutline.sections(notes: notes, outline: outline)
        // 第一卷 has no notes of its own but heads its chapters; 第二卷 has one.
        XCTAssertEqual(sections.map(\.title), ["第一卷", "第一章", "第二章", "第二卷"])
        XCTAssertEqual(sections.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(sections.map { $0.notes.count }, [0, 2, 1, 1])
    }

    func testChaptersWithoutNotesAreLeftOutAndEarlyNotesGetTheirOwnSection() {
        let sections = NotesOutline.sections(notes: [note(0, quote: "序前"), note(10, quote: "末")], outline: outline)
        XCTAssertEqual(sections.map(\.title), [NotesOutline.beforeContents, "第二卷"])
    }

    func testWithoutAnOutlineThereIsOneSectionInPageOrder() {
        let sections = NotesOutline.sections(notes: [note(5, quote: "后"), note(1, quote: "先")], outline: [])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, NotesOutline.everything)
        XCTAssertEqual(sections[0].notes.map(\.quote), ["先", "后"])
        XCTAssertEqual(NotesOutline.sections(notes: [], outline: outline).count, 0)
    }

    func testMarkdownAndTextCarryHeadingsPagesQuotesAndNotes() {
        let sections = NotesOutline.sections(notes: [note(3, quote: "学而时习之", text: "开篇"), note(10, kind: "矩形", color: nil)], outline: outline)
        let markdown = NotesOutline.markdown(title: "论语", sections: sections)
        XCTAssertTrue(markdown.hasPrefix("# 论语 — 笔记大纲"))
        XCTAssertTrue(markdown.contains("## 第一卷"))
        XCTAssertTrue(markdown.contains("### 第一章"))
        XCTAssertTrue(markdown.contains("第 4 页 · 高亮（黄）"))
        XCTAssertTrue(markdown.contains("> 学而时习之"))
        XCTAssertTrue(markdown.contains("笔记：开篇"))
        XCTAssertTrue(markdown.contains("（图形标注，无文本）"))
        let text = NotesOutline.plainText(title: "论语", sections: sections)
        XCTAssertTrue(text.contains("原文：学而时习之"))
        XCTAssertTrue(text.contains("  第一章"))
    }

    func testTheWordFileIsValidAndHasTheHeadings() throws {
        let sections = NotesOutline.sections(notes: [note(3, quote: "学而时习之", text: "开篇")], outline: outline)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("n.docx")
        try WordExport.writeNotesOutline(title: "论语", sections: sections, to: url)
        let helper = WordExportTests()
        XCTAssertTrue(try helper.unzip(["-t", url.path]).contains("No errors detected"))
        let xml = try helper.unzip(["-p", url.path, "word/document.xml"])
        XCTAssertTrue(xml.contains("论语 — 笔记大纲") && xml.contains("第一卷") && xml.contains("学而时习之") && xml.contains("笔记：开篇"))
        XCTAssertTrue(xml.contains("Heading1") && xml.contains("Heading2") && xml.contains("Heading3"))
    }
}

final class FlattenedExportTests: XCTestCase {
    func annotatedBook() throws -> PDFDocument {
        let book = try TextImport.render((1...40).map { "第\($0)行：学而时习之，不亦说乎？" }.joined(separator: "\n"), markdown: false)
        let box = try AnnotationShapes.make(tool: .rectangle, points: [CGPoint(x: 60, y: 600), CGPoint(x: 260, y: 660)], style: PenStyle(width: 2, alpha: 1), color: .red, fill: false, constrained: false).unwrap("没有生成")
        try book.page(at: 0).unwrap("无页面").addAnnotation(box)
        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 600, width: 28, height: 28), forType: .text, withProperties: nil)
        note.contents = "要点"
        try book.page(at: 0).unwrap("无页面").addAnnotation(note)
        return book
    }

    func testFlatteningDrawsTheAnnotationsIntoThePagesAndKeepsTheText() throws {
        let book = try annotatedBook()
        let pages = Array(0..<book.pageCount)
        let data = try ExportServices.flattenedPDF(book, pages: pages)
        let flat = try PDFDocument(data: data).unwrap("无法读取")
        XCTAssertEqual(flat.pageCount, book.pageCount)
        XCTAssertEqual(flat.page(at: 0)?.annotations.filter { ["Square", "Text"].contains($0.type ?? "") }.count, 0)
        // PDFKit reads some characters of a redrawn page back as radicals (⽽ for 而); the app's repair maps them back.
        let text = ReadingServices.repairIdeographs(flat.page(at: 0)?.string ?? "")
        XCTAssertTrue(text.contains("学而时习之"))
        // The text is there once, not twice: as often as on the original page (which holds only the first lines).
        let before = ReadingServices.repairIdeographs(book.page(at: 0)?.string ?? "")
        XCTAssertTrue(before.components(separatedBy: "学而时习之").count > 5)
        XCTAssertEqual(text.components(separatedBy: "学而时习之").count, before.components(separatedBy: "学而时习之").count)
    }

    func testTheSummaryPagesAreAppendedAfterTheBook() throws {
        let book = try annotatedBook()
        let notes = ReadingServices.notes(book)
        XCTAssertEqual(notes.count, 2)
        let combined = try ExportServices.withSummaryPages(book, notes: notes)
        XCTAssertTrue(combined.pageCount > book.pageCount)
        let last = combined.page(at: combined.pageCount - 1)?.string ?? ""
        let allText = (book.pageCount..<combined.pageCount).compactMap { combined.page(at: $0)?.string }.joined()
        XCTAssertTrue(allText.contains("要点") || last.contains("要点"))
        XCTAssertTrue(allText.contains("标注摘要"))
    }

    func testTheConfiguredExportFlattensAndAppendsSummaryPages() throws {
        let book = try annotatedBook()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ExportOptions()
        options.pdfMode = .flatten
        options.appendsNotes = true
        let target = directory.appendingPathComponent("out.pdf")
        let source = try book.dataRepresentation().unwrap("无法序列化")
        let spec = JobSpec(operation: .configured, source: source, pages: Array(0..<book.pageCount), destination: target, revision: UUID(), exportOptions: options)
        let result = try ExportServices.run(spec) { _ in }
        XCTAssertTrue(result.message.contains("摘要页"))
        let out = try PDFDocument(url: target).unwrap("无法读取输出")
        XCTAssertTrue(out.pageCount > book.pageCount)
        XCTAssertEqual(out.page(at: 0)?.annotations.filter { ["Square", "Text"].contains($0.type ?? "") }.count, 0)
    }

    func testOldSavedExportSettingsStillDecode() throws {
        let data = try JSONEncoder().encode(ExportOptions())
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        object["appendNotes"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(ExportOptions.self, from: stripped).appendsNotes)
    }
}

final class OutlineWithExcerptsTests: XCTestCase {
    private func card(_ kind: CardKind, text: String, comment: String = "", path: String? = nil, page: Int = 0) -> BoardCard {
        BoardCard(kind: kind, text: text, comment: comment,
                  source: path.map { SourceRef(path: $0, fileName: "a.pdf", page: page) },
                  x: 0, y: 0, width: 100, height: 100)
    }

    func testOnlyThisDocumentsExcerptsAreFiled() {
        let cards = [card(.text, text: "甲", comment: "批", path: "/a.pdf", page: 4),
                     card(.text, text: "乙", path: "/b.pdf", page: 1),
                     card(.note, text: "自由笔记"),
                     card(.note, text: "")]
        let result = NotesOutline.excerptNotes(cards: cards) { $0.path == "/a.pdf" }
        XCTAssertEqual(result.excerpts.map(\.quote), ["甲"])
        XCTAssertEqual(result.excerpts.first?.page, 4)
        XCTAssertEqual(result.excerpts.first?.note, "批")
        XCTAssertEqual(result.excerpts.first?.kind, "摘录")
        XCTAssertEqual(result.free.map(\.quote), ["自由笔记"])
    }

    func testExcerptsSitBesideAnnotationsInPageOrder() {
        let mark = AnnotationNote(page: 2, index: 0, kind: "高亮", quote: "标注", note: "")
        let excerpt = NotesOutline.excerptNotes(cards: [card(.text, text: "摘", path: "/a.pdf", page: 1)]) { _ in true }.excerpts
        let sections = NotesOutline.sections(notes: [mark] + excerpt, outline: [])
        XCTAssertEqual(sections.first?.notes.map(\.kind), ["摘录", "高亮"])
        XCTAssertEqual(Set((excerpt + [mark]).map(\.id)).count, 2)
    }

    func testImageExcerptsHaveAReadableLine() {
        let image = NotesOutline.excerptNotes(cards: [card(.image, text: "", path: "/a.pdf")]) { _ in true }.excerpts
        XCTAssertEqual(image.first?.kind, "截图摘录")
        XCTAssertFalse(image.first?.quote.isEmpty ?? true)
    }
}

final class TooltipDiagnosticsTests: XCTestCase {
    @MainActor func testChainReportsTheNearestTooltipAbove() {
        let parent = NSView(), child = NSView(), leaf = NSView()
        parent.toolTip = "完整路径"
        parent.addSubview(child); child.addSubview(leaf)
        let text = TooltipDiagnostics.describe(chainFrom: leaf)
        XCTAssertTrue(text.contains("完整路径"))
        XCTAssertTrue(text.contains("NSView"))
    }

    @MainActor func testChainSaysWhenThereIsNone() {
        XCTAssertTrue(TooltipDiagnostics.describe(chainFrom: NSView()).contains("无"))
        XCTAssertTrue(TooltipDiagnostics.describe(chainFrom: nil).contains("没有视图"))
    }
}

final class PerfLogTests: XCTestCase {
    func testLineHasPagesSecondsAndRate() {
        let text = PerfLog.line("识别文本", name: "书.pdf", pages: 20, seconds: 40)
        XCTAssertTrue(text.contains("| 识别文本 | 书.pdf | 20 页 | 40.0 秒 | 2.00 秒/页"))
    }

    func testRecordAppends() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("perf-" + UUID().uuidString + ".log")
        PerfLog.record("a", name: "x", pages: 1, seconds: 1, to: file)
        PerfLog.record("b", name: "y", pages: 0, seconds: 2, to: file)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[1].contains("秒/页"))
    }
}
