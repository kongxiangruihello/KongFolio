import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release028Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func pdf(_ text: [String]) throws -> Data { try Release027Tests().pdf(text) }
    func xml(_ url: URL, part: String = "word/document.xml") throws -> String { try WordExportTests().unzip(["-p", url.path, part]) }

    func testAdditionalTermsAreSamePageFoldedAndNeverChangePrimaryOffsets() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try pdf(["history 繁體資料", "history unwanted", "資料 only"]).write(to: root.appendingPathComponent("book.pdf"))
        let index = root.appendingPathComponent("index.sqlite")
        let terms = FolderSearchTerms(required: ["繁体资料"], excluded: ["unwanted"])
        let first = try FolderSearchService.run(folder: root, query: "HISTORY", recursive: true, indexURL: index, terms: terms)
        XCTAssertEqual(first.hits.count, 1); XCTAssertEqual(first.hits.first?.hit.page, 0)
        XCTAssertFalse(first.files[0].cached)
        let second = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: index, terms: FolderSearchTerms(excluded: ["繁体资料"]))
        XCTAssertEqual(second.hits.map { $0.hit.page }, [1]); XCTAssertTrue(second.files[0].cached)
        XCTAssertEqual(try FolderSearchService.verify(first.hits[0]).source.page, 0)
    }
    func testTermParsingPreservesSpacesWithinPhrases() {
        XCTAssertEqual(FolderSearchTerms.parse(" modern history，繁体；\n ,档案 "), ["modern history", "繁体", "档案"])
    }
    @MainActor func testSavedFoldersAndOldSettingsRemainReadable() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("FolderSearch/Settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(FolderSearchModel.Settings(folder: root, query: "history")).write(to: settings)
        let model = FolderSearchModel(storage: root); XCTAssertEqual(model.savedFolders.map(\.path), [root.path])
        let other = root.appendingPathComponent("other"); model.keepFolder(other); model.keepFolder(root)
        model.requiredTerms = "档案"; model.excludedTerms = "排除"; model.remember()
        let restored = FolderSearchModel(storage: root)
        XCTAssertEqual(restored.savedFolders.map(\.path), [root.path, other.path]); XCTAssertEqual(restored.requiredTerms, "档案")
        XCTAssertEqual(restored.excludedTerms, "排除")
        restored.forgetFolder(other); XCTAssertEqual(restored.savedFolders.map(\.path), [root.path])
    }
    @MainActor func testResultFilePageFiltersAndReportUseTheSameSubset() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try pdf(["history one", "history two"]).write(to: root.appendingPathComponent("book.pdf"))
        let model = FolderSearchModel(storage: root.appendingPathComponent("app")); model.folder = root; model.query = "history"; model.start()
        try await Release027Tests().wait(model)
        model.pageFilter = "2"; XCTAssertEqual(model.visibleResults.count, 1); XCTAssertEqual(model.visibleResults[0].hit.page, 1)
        XCTAssertFalse(model.report().contains("history one")); XCTAssertTrue(model.report().contains("history two"))
        model.fileFilter = "missing"; XCTAssertTrue(model.visibleResults.isEmpty)
        model.fileFilter = ""; model.pageFilter = "bad"; XCTAssertTrue(model.pageFilterInvalid); XCTAssertTrue(model.visibleResults.isEmpty)
    }
    @MainActor func testMultiResultExcerptsDeduplicateAndPreserveSourceLocations() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try pdf(["history one", "history two"]).write(to: root.appendingPathComponent("book.pdf"))
        let hits = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite")).hits
        let store = WorkspaceStore(storage: root.appendingPathComponent("app")); let model = FolderSearchModel(storage: store.storage)
        let added = await model.excerpt(hits, in: store); XCTAssertTrue(added); XCTAssertEqual(store.board.cards.count, 2)
        XCTAssertEqual(store.board.cards.map { $0.source?.page }, [0, 1]); XCTAssertFalse(store.board.cards[0].source!.rects.isEmpty)
        let repeated = await model.excerpt(hits, in: store); XCTAssertTrue(repeated); XCTAssertEqual(store.board.cards.count, 2)
    }
    @MainActor func testChangedSourceAbortsWholeExcerptBatch() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("book.pdf"); try pdf(["history one", "history two"]).write(to: file)
        let hits = try FolderSearchService.run(folder: root, query: "history", recursive: true, indexURL: root.appendingPathComponent("index.sqlite")).hits
        try pdf(["changed"]).write(to: file)
        let store = WorkspaceStore(storage: root.appendingPathComponent("app")); let model = FolderSearchModel(storage: store.storage)
        let added = await model.excerpt(hits, in: store); XCTAssertFalse(added); XCTAssertTrue(store.board.cards.isEmpty)
    }
    func testSourceLinkRoundTripPreservesUnicodeRectanglesAndRejectsInvalidData() throws {
        let source = SourceRef(path: "/tmp/中文 a&b.pdf", fileName: "中文.pdf", page: 3, pageLabel: "iv", rects: [CGRect(x: 10, y: 20, width: 30, height: 40)], anchor: "原文")
        XCTAssertEqual(SourceLink.source(try XCTUnwrap(SourceLink.url(source))), source)
        XCTAssertNil(SourceLink.source(URL(string: "https://example.com/source?ref=bad")!))
        XCTAssertNil(SourceLink.source(URL(string: "kongfolio://source?ref=bad")!))
        XCTAssertNil(SourceLink.url(SourceRef(path: "", fileName: "", page: 0)))
    }
    func testNotebookGroupsSelectedCardsAndSeparatesCommentFromQuote() throws {
        let source = SourceRef(path: "/tmp/book.pdf", fileName: "book.pdf", page: 2)
        let cards = [BoardCard(kind: .text, text: "引用甲", comment: "我的判断", source: source, x: 0, y: 0, width: 100, height: 100), BoardCard(kind: .note, text: "自由笔记", x: 0, y: 100, width: 100, height: 100)]
        let text = ExcerptNotebook.render(cards, title: "摘录", grouping: .chapter, outlines: [source.path: [OutlineEntry(page: 0, label: "第一章", depth: 0)]])
        XCTAssertTrue(text.contains("来源路径：/tmp/book.pdf")); XCTAssertTrue(text.contains("## book.pdf")); XCTAssertTrue(text.contains("### 第一章"))
        XCTAssertTrue(text.contains("> 引用甲")); XCTAssertTrue(text.contains("**我的评论**\n\n我的判断")); XCTAssertTrue(text.contains("kongfolio://source?ref="))
        XCTAssertTrue(text.contains("## 自由笔记")); XCTAssertTrue(text.contains("第 3 页"))
    }
    @MainActor func testNewPDFHasOneA4PageAndCanSerialize() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root); let workspace = store.newPDF()
        XCTAssertEqual(workspace.count, 1); XCTAssertEqual(workspace.page!.bounds(for: .mediaBox).size, TextImport.pageSize)
        XCTAssertTrue(workspace.dirty); XCTAssertEqual(PDFDocument(data: try workspace.pdfData())?.pageCount, 1)
    }
    @MainActor func testAllTextFormatsExportCurrentEditsAsSearchablePDF() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for (format, text) in [(TextDocumentFormat.markdown, "# 标题\n\nCurrent edit **history**"), (.plain, "Current edit history"), (.html, "<html><body><h1>标题</h1><p>Current edit <b>history</b></p></body></html>")] {
            let note = MarkdownNote(text: text, storage: root, format: format)
            let url = root.appendingPathComponent(format.fileExtension + ".pdf"); try note.writePDF(to: url)
            let document = try XCTUnwrap(PDFDocument(url: url)); XCTAssertTrue(document.pageCount > 0)
            XCTAssertTrue(document.string?.contains("history") ?? false)
            XCTAssertEqual(note.text, text); XCTAssertNil(note.fileURL)
        }
    }
    @MainActor func testEmptyPDFExportFailsWithoutOverwritingDestination() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("keep.pdf"); let sentinel = Data("existing".utf8); try sentinel.write(to: url)
        let note = MarkdownNote(storage: root)
        XCTAssertThrowsError(try note.writePDF(to: url)); XCTAssertEqual(try Data(contentsOf: url), sentinel)
    }
    @MainActor func testWordExportKeepsTextStylesEscapingAndLinksForAllFormats() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for (format, text) in [(TextDocumentFormat.markdown, "# Title\n\n**Bold** and *italic* [link](https://example.com) & <raw>"), (.plain, "plain & <text>\nline\ttab"), (.html, "<html><body><h1>Title</h1><p><b>Bold</b> and <i>italic</i> <a href='https://example.com'>link</a> &amp; text</p></body></html>")] {
            let url = root.appendingPathComponent(format.fileExtension + ".docx")
            try TextFileExport.writeWord(text, format: format, to: url)
            XCTAssertTrue(try WordExportTests().unzip(["-t", url.path]).contains("No errors detected"))
            let content = try xml(url)
            XCTAssertTrue(content.contains("&amp;")); XCTAssertFalse(content.contains("<raw>"))
            if format != .plain { XCTAssertTrue(content.contains("<w:b/>"), "Bold: \(format) \(content)"); XCTAssertTrue(content.contains("<w:i/>"), "Italic: \(format) \(content)"); XCTAssertTrue(try xml(url, part: "word/_rels/document.xml.rels").contains("https://example.com"), "Link: \(format)") }
            else { XCTAssertTrue(content.contains("&lt;text&gt;")); XCTAssertTrue(content.contains("<w:tab/>")) }
        }
    }
    @MainActor func testNotebookLinksAreClickableInPDFAndWord() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = SourceRef(path: "/tmp/book.pdf", fileName: "book.pdf", page: 2)
        let link = try XCTUnwrap(SourceLink.url(source))
        let text = "[返回原文](\(link.absoluteString))"
        let document = try TextImport.render(text, markdown: true)
        let links = try XCTUnwrap(PDFDocument(data: document.dataRepresentation()!)).page(at: 0)!.annotations.filter { $0.type == "Link" }
        XCTAssertEqual(links.count, 1); XCTAssertEqual(links.first?.url, link)
        let url = root.appendingPathComponent("note.docx"); try TextFileExport.writeWord(text, format: .markdown, to: url)
        XCTAssertTrue(try xml(url, part: "word/_rels/document.xml.rels").contains("kongfolio://source"))
    }
    @MainActor func testOCRCorrectionRebuildsLayerKeepsOriginalAndAnnotationsAndUndo() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = DocumentServicesTests().fixture(), workspace = Workspace(storage: root)
        let records = [RecognizedLine(text: "wrong", box: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.05))]
        let initial = try DocumentServices.searchablePage(original.page(at: 0)!, lines: records)
        workspace.document = PDFDocument(); workspace.document.insert(initial, at: 0)
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil); note.contents = "keep"
        initial.addAnnotation(note)
        workspace.updateMeta(0) { $0.ocrOriginal = DocumentServices.subset(original, indexes: [0]).dataRepresentation(); $0.ocrRegions = records }
        var changed = records; changed[0].text = "corrected"
        XCTAssertTrue(workspace.applyOCRCorrections(changed, page: 0))
        XCTAssertEqual(workspace.document.findString("corrected", withOptions: []).count, 1); XCTAssertTrue(workspace.document.findString("wrong", withOptions: []).isEmpty)
        XCTAssertEqual(workspace.meta(0).ocrRegions?[0].originalText, "wrong"); XCTAssertTrue(workspace.page!.annotations.contains { $0.contents == "keep" })
        var again = workspace.meta(0).ocrRegions!; again[0].text = "final"
        XCTAssertTrue(workspace.applyOCRCorrections(again, page: 0)); XCTAssertEqual(workspace.document.findString("final", withOptions: []).count, 1)
        XCTAssertTrue(workspace.document.findString("corrected", withOptions: []).isEmpty)
        XCTAssertEqual(workspace.meta(0).ocrRegions?[0].originalText, "wrong")
        let archive = try workspace.snapshot(); let restored = try ProjectContainer.decode(ProjectContainer.encode(archive))
        XCTAssertEqual(restored.ocrRegions?[0]?[0].originalText, "wrong")
        workspace.undo(); XCTAssertEqual(workspace.meta(0).ocrRegions?[0].text, "corrected")
        workspace.undo(); XCTAssertEqual(workspace.meta(0).ocrRegions?[0].text, "wrong")
    }
    @MainActor func testOCRWithoutOriginalCannotPretendToUpdatePDF() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root); workspace.document = DocumentServicesTests().fixture()
        let lines = [RecognizedLine(text: "before", box: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.05))]
        workspace.updateMeta(0) { $0.ocrRegions = lines }
        var changed = lines; changed[0].text = "after"
        XCTAssertFalse(workspace.applyOCRCorrections(changed, page: 0)); XCTAssertEqual(workspace.meta(0).ocrRegions, lines)
    }
    func testPageInspectionFindsBlankAndDuplicateButProtectsAnnotations() throws {
        let document = DocumentServicesTests().fixture()
        document.insert(document.page(at: 0)!.copy() as! PDFPage, at: 3)
        let blank = PDFPage(); blank.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox); document.insert(blank, at: 4)
        let annotated = blank.copy() as! PDFPage
        annotated.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)); document.insert(annotated, at: 5)
        let result = try PageInspection.scan(document.dataRepresentation()!)
        XCTAssertEqual(result.filter { $0.kind == .duplicate }.map(\.page), [3]); XCTAssertEqual(result.first { $0.page == 3 }?.original, 0)
        XCTAssertEqual(result.filter { $0.kind == .blank }.map(\.page), [4]); XCTAssertFalse(result.contains { $0.page == 5 })
    }
    func testInvisibleDifferentTextLayersAreNotDuplicatePages() throws {
        let source = DocumentServicesTests().fixture(), document = PDFDocument()
        for text in ["first", "second"] { document.insert(try DocumentServices.searchablePage(source.page(at: 0)!, lines: [RecognizedLine(text: text, box: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.05))]), at: document.pageCount) }
        XCTAssertTrue(try PageInspection.scan(document.dataRepresentation()!).isEmpty)
    }
    @MainActor func testInspectionDeletionRemapsMetadataAndCanBeUndone() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root); workspace.document = DocumentServicesTests().fixture()
        workspace.updateMeta(2) { $0.ocrRegions = [RecognizedLine(text: "third", box: .zero)] }
        let snapshot = try workspace.pdfData()
        XCTAssertTrue(workspace.removeInspectedPages([1], snapshot: snapshot)); XCTAssertEqual(workspace.count, 2); XCTAssertEqual(workspace.meta(1).ocrRegions?.first?.text, "third")
        workspace.undo(); XCTAssertEqual(workspace.count, 3); XCTAssertEqual(workspace.meta(2).ocrRegions?.first?.text, "third")
    }
    @MainActor func testInspectionRejectsChangedSnapshotAndRemovingEveryPage() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root); workspace.document = DocumentServicesTests().fixture()
        let snapshot = try workspace.pdfData()
        XCTAssertFalse(workspace.removeInspectedPages([0, 1, 2], snapshot: snapshot)); XCTAssertEqual(workspace.count, 3)
        workspace.document.page(at: 0)!.rotation = 90; workspace.edited()
        XCTAssertFalse(workspace.removeInspectedPages([1], snapshot: snapshot)); XCTAssertEqual(workspace.count, 3)
    }
}
