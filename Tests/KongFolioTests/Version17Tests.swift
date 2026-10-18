import AppKit
import PDFKit
import XCTest
@testable import KongFolio

final class AnnotationArrangeTests: XCTestCase {
    private let rects = [CGRect(x: 10, y: 10, width: 20, height: 10), CGRect(x: 50, y: 40, width: 30, height: 20), CGRect(x: 120, y: 5, width: 10, height: 10)]

    func testAlignLeftAndRight() {
        XCTAssertEqual(AnnotationLayout.align(rects, .left).map(\.minX), [10, 10, 10])
        XCTAssertEqual(AnnotationLayout.align(rects, .right).map(\.maxX), [130, 130, 130])
    }

    func testAlignTopBottomAndCentres() {
        XCTAssertEqual(AnnotationLayout.align(rects, .top).map(\.maxY), [60, 60, 60])
        XCTAssertEqual(AnnotationLayout.align(rects, .bottom).map(\.minY), [5, 5, 5])
        XCTAssertEqual(AnnotationLayout.align(rects, .centerY).map(\.midY), [32.5, 32.5, 32.5])
    }

    func testDistributeKeepsTheOutermostAndEqualisesGaps() {
        let spread = AnnotationLayout.distribute(rects, horizontally: true)
        XCTAssertEqual(spread[0].minX, 10)
        XCTAssertEqual(spread[2].maxX, 130)
        let gap1 = spread[1].minX - spread[0].maxX
        let gap2 = spread[2].minX - spread[1].maxX
        XCTAssertEqual(gap1, gap2, accuracy: 0.001)
    }

    func testTwoRectanglesAreNotDistributed() {
        XCTAssertEqual(AnnotationLayout.distribute(Array(rects.prefix(2)), horizontally: true), Array(rects.prefix(2)))
    }

    func testTextBoxHeightGrowsWithSizeAndText() {
        let small = AnnotationTextStyle.height(for: "天地玄黄宇宙洪荒", size: 12, width: 100)
        let large = AnnotationTextStyle.height(for: "天地玄黄宇宙洪荒", size: 24, width: 100)
        XCTAssertTrue(large > small)
        XCTAssertTrue(AnnotationTextStyle.height(for: "a\nb\nc", size: 12, width: 200) > AnnotationTextStyle.height(for: "a", size: 12, width: 200))
    }
}

final class AnnotationExportTests: XCTestCase {
    private func document() -> PDFDocument {
        let doc = PDFDocument()
        for _ in 0..<2 { doc.insert(PDFPage(), at: doc.pageCount) }
        let page = doc.page(at: 0)!
        let box = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 30), forType: .square, withProperties: nil)
        box.color = .red
        page.addAnnotation(box)
        let text = PDFAnnotation(bounds: CGRect(x: 10, y: 60, width: 100, height: 30), forType: .freeText, withProperties: nil)
        text.contents = "批"
        page.addAnnotation(text)
        let other = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 50), forType: .circle, withProperties: nil)
        doc.page(at: 1)!.addAnnotation(other)
        return doc
    }

    private func markupCount(_ doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.filter { AnnotationExport.isMarkup($0) }.count ?? 0) }
    }

    func testCleanCopyHasNoMarkupAndTheOriginalIsUntouched() throws {
        let doc = document()
        let before = markupCount(doc)
        let clean = try XCTUnwrap(AnnotationExport.copy(of: doc, keeping: { _ in false }))
        XCTAssertEqual(markupCount(clean), 0)
        XCTAssertEqual(markupCount(doc), before)
        XCTAssertEqual(clean.pageCount, 2)
    }

    func testFilteredCopyKeepsOnlyTheAccepted() throws {
        let kept = try XCTUnwrap(AnnotationExport.copy(of: document(), keeping: { $0.kind == "文字框" }))
        XCTAssertEqual(markupCount(kept), 1)
    }

    func testAllKeptWhenNoFilter() throws {
        let all = try XCTUnwrap(AnnotationExport.copy(of: document(), keeping: nil))
        XCTAssertEqual(markupCount(all), 3)
    }

    func testListPagesAreAppended() throws {
        let notes = ReadingServices.notes(document())
        let text = AnnotationExport.listText(title: "书", notes: notes, outline: [])
        XCTAssertTrue(text.contains("批注清单"))
        let list = try XCTUnwrap(AnnotationExport.textPages(text))
        XCTAssertTrue(list.pageCount >= 1)
        let joined = try XCTUnwrap(AnnotationExport.appending(list, to: document()))
        XCTAssertEqual(joined.pageCount, 2 + list.pageCount)
    }

    func testLongListsRunOntoMorePages() throws {
        let long = (0..<400).map { "第 \($0) 条：天地玄黄，宇宙洪荒。" }.joined(separator: "\n")
        XCTAssertTrue(try XCTUnwrap(AnnotationExport.textPages(long)).pageCount > 1)
    }
}

final class OutlineDraftTests: XCTestCase {
    private func note(_ page: Int, _ quote: String, text: String = "") -> AnnotationNote {
        AnnotationNote(page: page, index: 0, kind: "高亮", quote: quote, note: text)
    }

    private func draft() -> OutlineDraft {
        OutlineDraft(sections: [NotesSection(title: "一", depth: 0, notes: [note(0, "甲"), note(1, "乙")]), NotesSection(title: "二", depth: 0, notes: [note(5, "丙")])])
    }

    func testMoveWithinAndAcrossChapters() {
        var d = draft()
        d.move("1-0", by: -1)
        XCTAssertEqual(d.sections[0].notes.map(\.quote), ["乙", "甲"])
        d.move("1-0", by: -1)
        XCTAssertEqual(d.sections[0].notes.map(\.quote), ["乙", "甲"])
        d.move("5-0", toSection: 0)
        XCTAssertEqual(d.sections[0].notes.map(\.quote), ["乙", "甲", "丙"])
        XCTAssertEqual(d.exportSections.count, 1)
    }

    func testTagsAreParsedAndShown() {
        XCTAssertEqual(OutlineDraft.parseTags("重点， 待查,重点"), ["重点", "待查"])
        var d = draft()
        d.setTags("0-0", ["重点"])
        XCTAssertTrue(NotesOutline.markdown(title: "书", sections: d.sections).contains("#重点"))
    }

    func testMergeDuplicatesIgnoresTraditionalOrSimplified() {
        var d = OutlineDraft(sections: [NotesSection(title: "一", depth: 0, notes: [note(0, "學問", text: "甲"), note(3, "学问", text: "乙")])])
        XCTAssertEqual(d.mergeDuplicates(), 1)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.sections[0].notes[0].note, "甲\n乙")
    }

    func testRemove() {
        var d = draft()
        d.remove("0-0")
        XCTAssertEqual(d.count, 2)
    }
}

final class VerticalLayerTests: XCTestCase {
    /// Two columns of five characters: the right one is read first, top to bottom.
    private func layer(shuffled: Bool = false) -> [OrderedText.LayerCharacter] {
        var chars: [OrderedText.LayerCharacter] = []
        for (x, text) in [(300.0, "天地玄黄宇"), (200.0, "宙洪荒日月")] {
            for (row, ch) in text.enumerated() {
                chars.append(OrderedText.LayerCharacter(text: String(ch), rect: CGRect(x: x, y: 700 - Double(row) * 24, width: 20, height: 20)))
            }
        }
        return shuffled ? chars.reversed() : chars
    }

    func testRecognisesAVerticalLayerAndNotAHorizontalOne() {
        XCTAssertTrue(OrderedText.looksVertical(layer() + layer()))
        let horizontal = (0..<20).map { OrderedText.LayerCharacter(text: "a", rect: CGRect(x: Double($0) * 12, y: 700, width: 10, height: 12)) }
        XCTAssertFalse(OrderedText.looksVertical(horizontal))
    }

    func testReadingOrderIsRightColumnFirstTopDown() {
        let glyphs = OrderedText.glyphs(fromLayer: layer(shuffled: true), cropBox: CGRect(x: 0, y: 0, width: 400, height: 800), rotation: 0)
        XCTAssertEqual(glyphs.map(\.text).joined(), "天地玄黄宇宙洪荒日月")
        XCTAssertEqual(OrderedText.text(of: glyphs) { _ in true }, "天地玄黄宇\n宙洪荒日月")
    }
}

final class ReadingProgressTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let pages: Set<Int> = [0, 1, 2, 3, 7, 9, 10]
        XCTAssertEqual(ReadingProgress.encode(pages), "0-3,7,9-10")
        XCTAssertEqual(ReadingProgress.decode("0-3,7,9-10"), pages)
        XCTAssertEqual(ReadingProgress.decode("x,5-2,3"), [3])
    }

    func testChaptersCountTheirOwnPages() {
        let outline = [OutlineEntry(page: 0, label: "卷一", depth: 0, point: nil), OutlineEntry(page: 2, label: "第一章", depth: 1, point: nil), OutlineEntry(page: 5, label: "卷二", depth: 0, point: nil)]
        let chapters = ReadingProgress.chapters(outline: outline, visited: [0, 1, 2, 5], pageCount: 8)
        XCTAssertEqual(chapters.map(\.pageCount), [5, 3, 3])
        XCTAssertEqual(chapters.map(\.visitedCount), [3, 1, 1])
    }

    func testNextUnreadWrapsRound() {
        let progress = ReadingProgress(visited: [0, 1, 2], last: 2)
        XCTAssertEqual(progress.nextUnread(after: 1, pageCount: 4), 3)
        XCTAssertEqual(progress.nextUnread(after: 3, pageCount: 4), 3)
        XCTAssertEqual(ReadingProgress(visited: [0, 1], last: 1).nextUnread(after: 0, pageCount: 2), nil)
    }

    func testStorePerFile() {
        let suite = UserDefaults(suiteName: "kongfolio-progress-" + UUID().uuidString)!
        ReadingProgress(visited: [1, 2, 3], last: 3).save(path: "/a.pdf", defaults: suite)
        XCTAssertEqual(ReadingProgress.load(path: "/a.pdf", defaults: suite).visited, [1, 2, 3])
        XCTAssertEqual(ReadingProgress.load(path: "/b.pdf", defaults: suite), ReadingProgress())
        ReadingProgress.clear(path: "/a.pdf", defaults: suite)
        XCTAssertEqual(ReadingProgress.load(path: "/a.pdf", defaults: suite), ReadingProgress())
    }
}

final class DiagnosticReportTests: XCTestCase {
    func testReportMentionsVersionFactsAndLogs() {
        let text = DiagnosticReport.text(version: "0.17.0", build: "17", system: "macOS 15", facts: ["文档：3 页"], perf: ["一行"], hover: [])
        XCTAssertTrue(text.contains("KongFolio 0.17.0（build 17）"))
        XCTAssertTrue(text.contains("文档：3 页"))
        XCTAssertTrue(text.contains("一行"))
        XCTAssertTrue(text.contains("（没有）"))
    }
}

final class Version18Tests: XCTestCase {
    @MainActor func testExportCheckBringsHiddenLayersBack() {
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        space.hiddenKinds = ["高亮"]
        XCTAssertTrue(space.checkDraftsForExport())
        XCTAssertTrue(space.hiddenKinds.isEmpty)
    }

    func testDraftSurvivesAsAValue() {
        var draft = OutlineDraft(sections: [NotesSection(title: "一", depth: 0, notes: [AnnotationNote(page: 0, index: 0, kind: "高亮", quote: "甲", note: ""), AnnotationNote(page: 1, index: 0, kind: "高亮", quote: "乙", note: "")])])
        draft.move("1-0", by: -1)
        let kept = draft
        XCTAssertEqual(kept.sections[0].notes.map(\.quote), ["乙", "甲"])
    }
}

final class Version19Tests: XCTestCase {
    func testLinkTargets() {
        XCTAssertEqual(LinkTarget.parse("12", pageCount: 30), .page(11))
        XCTAssertEqual(LinkTarget.parse(" 1 ", pageCount: 30), .page(0))
        XCTAssertEqual(LinkTarget.parse("31", pageCount: 30), nil)
        XCTAssertEqual(LinkTarget.parse("0", pageCount: 30), nil)
        XCTAssertEqual(LinkTarget.parse("example.com/a", pageCount: 3), .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(LinkTarget.parse("http://x.org", pageCount: 3), .web(URL(string: "http://x.org")!))
        XCTAssertEqual(LinkTarget.parse("不是网址", pageCount: 3), nil)
        XCTAssertEqual(LinkTarget.parse("", pageCount: 3), nil)
    }

    func testShiftAfterInsertion() {
        XCTAssertEqual([0, 2, 3, 5].map { PageEditing.shifted($0, insertedAt: 3) }, [0, 2, 4, 6])
    }

    func testPasteStaysOnThePage() {
        let page = CGRect(x: 0, y: 0, width: 200, height: 300)
        XCTAssertEqual(PageEditing.pasteBounds(CGRect(x: 10, y: 100, width: 50, height: 20), in: page), CGRect(x: 24, y: 86, width: 50, height: 20))
        let edge = PageEditing.pasteBounds(CGRect(x: 170, y: 5, width: 30, height: 20), in: page)
        XCTAssertEqual(edge.maxX, 200)
        XCTAssertEqual(edge.minY, 0)
    }

    func testSearchRing() {
        XCTAssertEqual(PageEditing.ring(nil, step: 1, count: 3), 0)
        XCTAssertEqual(PageEditing.ring(nil, step: -1, count: 3), 2)
        XCTAssertEqual(PageEditing.ring(2, step: 1, count: 3), 0)
        XCTAssertEqual(PageEditing.ring(0, step: -1, count: 3), 2)
        XCTAssertEqual(PageEditing.ring(0, step: 1, count: 0), nil)
    }

    @MainActor func testBlankPageIsInsertedWithMetaAndBookmarksShifted() {
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        let doc = PDFDocument()
        for _ in 0..<3 { let p = PDFPage(); p.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox); doc.insert(p, at: doc.pageCount) }
        space.document = doc
        space.updateMeta(2) { $0.ocrRegions = [RecognizedLine(text: "字", box: .zero)] }
        space.selection = 0
        space.insertBlankPage()
        XCTAssertEqual(space.document.pageCount, 4)
        XCTAssertEqual(space.selection, 1)
        XCTAssertEqual(space.document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 400))
        XCTAssertEqual(space.meta(3).ocrRegions?.count, 1)
        XCTAssertEqual(space.meta(1).ocrRegions == nil, true)
    }

    @MainActor func testPasteMakesCopiesOnTheCurrentPage() {
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        let doc = PDFDocument()
        for _ in 0..<2 { let p = PDFPage(); p.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox); doc.insert(p, at: doc.pageCount) }
        space.document = doc
        let mark = PDFAnnotation(bounds: CGRect(x: 20, y: 200, width: 60, height: 30), forType: .square, withProperties: nil)
        doc.page(at: 0)?.addAnnotation(mark)
        space.selectedAnnotation = mark
        space.copySelectedAnnotations()
        space.selection = 1
        space.pasteAnnotations()
        XCTAssertEqual(doc.page(at: 1)?.annotations.filter { $0.type == "Square" }.count, 1)
        XCTAssertEqual(doc.page(at: 0)?.annotations.filter { $0.type == "Square" }.count, 1)
    }
}
