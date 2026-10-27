import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release030Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func pdf(_ text: [String]) throws -> Data { try Release027Tests().pdf(text) }
    func text(_ root: URL, name: String, value: String) throws -> URL { let url = root.appendingPathComponent(name); try value.write(to: url, atomically: true, encoding: .utf8); return url }
    func testMixedFilesSearchAndCacheKeepEditorOffsets() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.md", "b.html", "c.txt"] { _ = try text(root, name: name, value: "😀 繁體資料 history") }
        try pdf(["history PDF"]).write(to: root.appendingPathComponent("d.pdf"))
        let first = try FolderSearchService.run(folder: root, query: "繁体资料", recursive: true, indexURL: root.appendingPathComponent("index.sqlite"), includeText: true)
        XCTAssertEqual(first.files.count, 4); XCTAssertEqual(first.hits.count, 3)
        for hit in first.hits { XCTAssertEqual(hit.hit.range, NSRange(location: 3, length: 4)); XCTAssertNotNil(try FolderSearchService.verify(hit).text) }
        let cached = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite"), includeText: true)
        XCTAssertEqual(cached.hits.count, 4); XCTAssertTrue(cached.files.allSatisfy(\.cached))
    }
    func testSavedTextChangeInvalidatesHitAndExcerptBatch() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try text(root, name: "a.md", value: "history")
        let hits = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite"), includeText: true).hits
        XCTAssertEqual(try FolderSearchService.verifiedExcerpts(hits).count, 1)
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FolderSearchService.verify(hits[0])); XCTAssertThrowsError(try FolderSearchService.verifiedExcerpts(hits))
    }
    @MainActor func testUnsavedNoteSearchOpensCurrentBufferAndRejectsChanges() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), note = store.newNote(); note.text = "😀 history 未保存"
        var cache: [String: String] = [:]
        let file = try store.searchSnapshots()[0].search(query: "history", limit: 100, terms: FolderSearchTerms(), includeAnnotations: true, cache: &cache)
        XCTAssertEqual(file.hits.count, 1); XCTAssertEqual(file.hits[0].hit.range.location, 3)
        XCTAssertTrue(try store.openLiveSearch(file.hits[0])); XCTAssertEqual(store.activeNote?.id, note.id)
        note.text += " changed"; XCTAssertThrowsError(try store.openLiveSearch(file.hits[0]))
    }
    @MainActor func testLivePDFReplacesDiskSearchAndIncludesUnsavedAnnotations() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("book.pdf"); let bytes = try pdf(["history body"]); try bytes.write(to: file)
        let store = WorkspaceStore(storage: root.appendingPathComponent("app")), workspace = store.newPDF()
        workspace.document = PDFDocument(data: bytes)!; workspace.sourceURL = file
        let annotation = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 80, height: 30), forType: .freeText, withProperties: nil); annotation.contents = "history comment"; workspace.page!.addAnnotation(annotation); workspace.edited()
        let snapshot = try store.searchSnapshots()
        let result = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite"), includeAnnotations: true, live: snapshot)
        XCTAssertEqual(result.files.count, 1); XCTAssertEqual(result.hits.count, 2)
        let hit = try XCTUnwrap(result.hits.first { $0.category == "当前批注" }); XCTAssertEqual(hit.sourceRect, annotation.bounds)
        XCTAssertTrue(try store.openLiveSearch(hit)); workspace.edited(); XCTAssertThrowsError(try store.openLiveSearch(hit))
    }
    func testSavedPDFAnnotationSearchLocatesAnnotationNotBodyRange() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = PDFDocument(data: try pdf(["body"]))!, page = doc.page(at: 0)!
        let mark = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 40, height: 40), forType: .freeText, withProperties: nil); mark.contents = "批注 history"; page.addAnnotation(mark)
        try doc.dataRepresentation()!.write(to: root.appendingPathComponent("book.pdf"))
        let results = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite"), includeAnnotations: true)
        XCTAssertEqual(results.hits.count, 1); XCTAssertEqual(results.hits[0].category, "批注")
        XCTAssertEqual(try FolderSearchService.verify(results.hits[0]).source.rects, [mark.bounds])
    }
    @MainActor func testCardFingerprintStableAndChangesAreRejected() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), id = store.board.addNote(text: "history card")
        let snapshot = try XCTUnwrap(try store.searchSnapshots().first { $0.card?.id == id }); var cache: [String: String] = [:]
        let hit = try XCTUnwrap(try snapshot.search(query: "history", limit: 100, terms: FolderSearchTerms(), includeAnnotations: true, cache: &cache).hits.first)
        XCTAssertTrue(try store.openLiveSearch(hit)); XCTAssertEqual(store.board.focusedID, id)
        store.board.setText(id, "changed"); XCTAssertThrowsError(try store.openLiveSearch(hit))
    }
    @MainActor func testMixedLiveAndDiskExcerptFailureAddsNothing() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root.appendingPathComponent("app")), note = store.newNote(); note.text = "history unsaved"
        _ = try text(root, name: "disk.txt", value: "history disk")
        let hits = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite"), includeText: true, live: store.searchSnapshots()).hits
        note.text = "changed"; let result = await store.folderSearch.excerpt(hits, in: store)
        XCTAssertFalse(result); XCTAssertTrue(store.board.cards.isEmpty)
    }
    func testNotebookImageIsEmbeddedInPDFAndWord() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let card = BoardCard(kind: .image, imageData: try Release029Tests().png(), x: 0, y: 0, width: 100, height: 100)
        let note = ExcerptNotebook.render([card], title: "图片笔记", grouping: .file)
        XCTAssertTrue(note.contains("data:image/png;base64,"))
        let document = try RichTextDocument(note, format: .markdown); XCTAssertEqual(try document.pdf().pageCount, 1)
        let file = root.appendingPathComponent("note.docx"); try RichTextWord.write(document, to: file)
        XCTAssertTrue(try WordExportTests().unzip(["-Z1", file.path]).contains("word/media/"))
    }
    func testPortablePackageRelocationAndSourceVerification() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("书.pdf"); try pdf(["history"]).write(to: source)
        let card = BoardCard(kind: .image, imageData: try Release029Tests().png(), source: SourceRef(path: source.path, fileName: "书.pdf", page: 0, anchor: "history"), x: 0, y: 0, width: 100, height: 100)
        let zip = root.appendingPathComponent("pack.zip")
        try NotebookPackage.write(cards: [card], title: "摘录", grouping: .file, includeSources: true, to: zip)
        let moved = root.appendingPathComponent("换位置"); try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); extract.arguments = ["-x", "-k", zip.path, moved.path]; try extract.run(); extract.waitUntilExit(); XCTAssertEqual(extract.terminationStatus, 0); try FileManager.default.removeItem(at: source)
        let text = try String(contentsOf: moved.appendingPathComponent("摘录笔记.md"))
        let regex = try NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)))
        let url = try XCTUnwrap(URL(string: (text as NSString).substring(with: match.range))), ref = try XCTUnwrap(SourceLink.source(url))
        let resolved = try SourceLink.resolved(ref, baseURL: moved)
        XCTAssertTrue(resolved.path.hasPrefix(moved.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        XCTAssertEqual(try RichTextDocument(text, format: .markdown, baseURL: moved).pdf().pageCount, 1)
        let rebased = try SourceLink.rebasedText(text, baseURL: moved); XCTAssertFalse(rebased.isEmpty)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: resolved.path)); XCTAssertThrowsError(try SourceLink.resolved(ref, baseURL: moved))
    }
    func testPortableSourceRejectsTraversalAndMissingContext() throws {
        let ref = SourceRef(path: "/old.pdf", fileName: "old.pdf", page: 0, relativePath: "../escape.pdf")
        XCTAssertThrowsError(try SourceLink.resolved(ref, baseURL: URL(fileURLWithPath: "/tmp")))
        XCTAssertThrowsError(try SourceLink.resolved(ref, baseURL: nil))
    }
    func testFailedPackageLeavesExistingOutputUnchanged() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pack.zip"); try Data("keep".utf8).write(to: file)
        let card = BoardCard(kind: .text, source: SourceRef(path: "/missing-source.pdf", fileName: "missing.pdf", page: 0), x: 0, y: 0, width: 100, height: 100)
        XCTAssertThrowsError(try NotebookPackage.write(cards: [card], title: "t", grouping: .file, includeSources: true, to: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }
    func testWordMarginsRequireRepeatedEdgesAndDoNotDeleteInteriorText() {
        let texts = (1...4).map { "历史研究\n正文甲\n历史研究\n正文乙\n正文丙\n\($0)" }
        let candidates = WordCleanup.candidates(texts); XCTAssertEqual(candidates.count, 2)
        var options = WordExportOptions(); options.removeRunningMargins = true; options.mergeLines = false
        let page = WordCleanup.prepare(index: 0, label: "i", text: texts[0], regions: nil, options: options, margins: Set(candidates.map(\.id)))
        XCTAssertEqual(page.paragraphs.filter { $0.text == "历史研究" }.count, 1)
        XCTAssertFalse(page.paragraphs.contains { $0.text == "1" }); XCTAssertEqual(page.label, "i")
        XCTAssertTrue(WordCleanup.candidates(Array(texts.prefix(2))).isEmpty)
    }
    func testWordMarginsAreOptInAndCanBeIndividuallyExcluded() {
        let text = "页眉\n甲\n乙\n丙\n1", margins: Set<String> = [WordCleanup.key("页眉", top: true), WordCleanup.key("1", top: false)]
        var options = WordExportOptions(); options.mergeLines = false
        XCTAssertEqual(WordCleanup.prepare(index: 0, label: nil, text: text, regions: nil, options: options, margins: margins).paragraphs.count, 5)
        options.removeRunningMargins = true
        let page = WordCleanup.prepare(index: 0, label: nil, text: text, regions: nil, options: options, margins: [WordCleanup.key("页眉", top: true)])
        XCTAssertEqual(page.paragraphs.map(\.text), ["甲", "乙", "丙", "1"])
    }
    func testWordHeadingsStaySeparateAndCorrectedOCRWins() throws {
        let options = WordExportOptions()
        let page = WordCleanup.prepare(index: 0, label: nil, text: "第一章 历史\n一句未完\n继续。\n一、背景\n正文。", regions: nil, options: options, margins: [])
        XCTAssertEqual(page.paragraphs.map(\.heading), [1, 0, 2, 0]); XCTAssertEqual(page.paragraphs[1].text, "一句未完继续。")
        let doc = PDFDocument(data: try pdf(["old"]))!
        let regions = [RecognizedLine(text: "corrected OCR", box: CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.05))]
        XCTAssertEqual(WordCleanup.raw(doc.page(at: 0)!, regions: regions), "corrected OCR")
    }
    func testWordPreviewAndActualXMLUseSamePreparedParagraphs() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = PDFDocument(data: try pdf(["第一章 历史\n正文未完\n继续。", "第二章\n正文。", "第三章\n结束。"]))!
        var options = WordExportOptions(); options.content = .textOnly; options.pageMarks = true; options.printedPageLabels = true
        let preview = try WordCleanup.inspect(doc, pages: [0, 1, 2], options: options, regions: [:])
        let output = root.appendingPathComponent("book.docx"); _ = try WordExport.write(doc, pages: [0, 1, 2], outline: [], options: options, to: output)
        let xml = try WordExportTests().unzip(["-p", output.path, "word/document.xml"])
        for page in preview.pages { for paragraph in page.paragraphs { XCTAssertTrue(xml.contains(WordExport.escape(paragraph.text))) } }
        XCTAssertTrue(xml.contains("Heading1")); XCTAssertTrue(xml.contains("第 1 页"))
    }
    func testOldWordSettingsDecodeWithoutNewOptions() throws {
        let data = Data(#"{"content":"仅文字","imageSize":"标准","mergeLines":true,"pageMarks":true,"keepColumns":false,"replacements":[]}"#.utf8)
        let options = try JSONDecoder().decode(WordExportOptions.self, from: data)
        XCTAssertNil(options.removeRunningMargins); XCTAssertNil(options.printedPageLabels)
    }
    func testTextDifferenceFindsSeparatedChineseChangesWithCorrectUTF16() throws {
        let old = "😀第一章：历史。第二章：资料。结尾相同", new = "😀第一章：近代史。第二章：档案。结尾相同"
        let result = try DetailedDifference.text(old, new)
        XCTAssertFalse(result.coarse); XCTAssertTrue(result.chunks.count >= 2)
        for chunk in result.chunks { if let range = chunk.before { XCTAssertEqual((old as NSString).substring(with: range), chunk.old) }; if let range = chunk.after { XCTAssertEqual((new as NSString).substring(with: range), chunk.new) } }
        XCTAssertTrue(result.chunks.allSatisfy { ($0.before?.location ?? Int.max) >= 2 })
    }
    func testTextDifferenceInsertionDeletionIdenticalAndBoundedFallback() throws {
        let insertion = try DetailedDifference.text("abc", "ab新增c"); XCTAssertEqual(insertion.chunks.count, 1); XCTAssertNil(insertion.chunks[0].before); XCTAssertEqual(insertion.chunks[0].new, "新增")
        let deletion = try DetailedDifference.text("ab删除c", "abc"); XCTAssertNil(deletion.chunks[0].after); XCTAssertEqual(deletion.chunks[0].old, "删除")
        XCTAssertTrue(try DetailedDifference.text("相同", "相同").chunks.isEmpty)
        let large = try DetailedDifference.text(String(repeating: "甲", count: 50), String(repeating: "乙", count: 50), budget: 10)
        XCTAssertTrue(large.coarse); XCTAssertEqual(large.chunks.count, 1)
    }
    func testImageDifferenceDetectsLocalChangeWithoutMutatingPages() throws {
        let doc = PDFDocument(data: try pdf(["history"]))!, page = doc.page(at: 0)!, copy = page.copy() as! PDFPage
        let unchanged = try DetailedDifference.image(page, copy, dimension: 256); XCTAssertEqual(unchanged.changedPixels, 0)
        let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 80, height: 80), forType: .square, withProperties: nil); annotation.color = .red; annotation.interiorColor = .red; copy.addAnnotation(annotation)
        let changed = try DetailedDifference.image(page, copy, dimension: 256)
        XCTAssertTrue(changed.changedPixels > 0); XCTAssertFalse(changed.regions.isEmpty); XCTAssertNotNil(NSImage(data: changed.mask)); XCTAssertNotNil(NSImage(data: changed.overlay))
        XCTAssertEqual(page.annotations.count, 0)
    }
    func testSheetSizeFitsSmallParentAndScreen() {
        let size = SheetMetrics.size(preferred: CGSize(width: 1100, height: 900), parent: CGSize(width: 500, height: 400), screen: CGSize(width: 800, height: 600))
        XCTAssertEqual(size.width, 476); XCTAssertEqual(size.height, 352)
    }
}
