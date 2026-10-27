import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release029Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func png() throws -> Data { try XCTUnwrap(SignatureImage.pngData(SignatureTests().photo(gradient: false))) }
    func xml(_ url: URL, _ part: String = "word/document.xml") throws -> String { try WordExportTests().unzip(["-p", url.path, part]) }
    func testMarkdownTableImageAndLinkSurvivePDFAndWord() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try png().write(to: root.appendingPathComponent("figure.png"))
        let source = "# Research\n\n| Name | Detail |\n| --- | --- |\n| Alpha | **Bold** |\n\n![Figure](figure.png)\n\n[Source](https://example.com/book)"
        let rich = try RichTextDocument(source, format: .markdown, baseURL: root)
        let pdf = try rich.pdf(); XCTAssertTrue(pdf.string?.contains("Alpha") ?? false)
        XCTAssertTrue(pdf.page(at: 0)!.annotations.contains { $0.url?.host == "example.com" })
        let url = root.appendingPathComponent("out.docx"); try RichTextWord.write(rich, to: url)
        XCTAssertTrue(try xml(url).contains("<w:tbl>")); XCTAssertTrue(try xml(url).contains("<w:drawing>"))
        XCTAssertTrue(try xml(url, "word/_rels/document.xml.rels").contains("media/image1.png"))
        XCTAssertTrue(try WordExportTests().unzip(["-t", url.path]).contains("No errors detected"))
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_QA_OUTPUT"] {
            let target = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try pdf.dataRepresentation()!.write(to: target.appendingPathComponent("rich-preview.pdf"))
            try RichTextWord.write(rich, to: target.appendingPathComponent("rich-export.docx"))
        }
    }
    func testHTMLStructureRetainsImagesTablesLinksAndDropsScripts() throws {
        let data = try png()
        let html = "<html><head><script>bad()</script></head><body><h1>Document</h1><p><b>Bold</b> <i>Italic</i> <a href='https://example.com'>Source</a></p><table><tr><th>Header</th><th>Year</th></tr><tr><td>Archive</td><td>1911</td></tr></table><img src='data:image/png;base64,\(data.base64EncodedString())'><script>not in output</script></body></html>"
        let rich = try RichTextDocument(html, format: .html)
        let pdf = try rich.pdf(); XCTAssertTrue(pdf.string?.contains("Archive") ?? false); XCTAssertFalse(pdf.string?.contains("not in output") ?? true)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("html.docx"); try RichTextWord.write(rich, to: file)
        let content = try xml(file); XCTAssertTrue(content.contains("<w:tbl>")); XCTAssertTrue(content.contains("<w:drawing>")); XCTAssertTrue(content.contains("<w:b/>")); XCTAssertTrue(content.contains("<w:i/>"))
    }
    func testHTMLWrapperKeepsSeparateHeadingsAndParagraphs() throws {
        let rich = try RichTextDocument("<html><body><h1>Heading</h1><p>First paragraph</p><p>Second paragraph</p></body></html>", format: .html)
        XCTAssertEqual(rich.blocks.count, 3)
        if case .paragraph(_, let level) = rich.blocks[0] { XCTAssertEqual(level, 1) } else { XCTAssertTrue(false) }
        let doc = try rich.pdf(); XCTAssertTrue(doc.string?.contains("Second paragraph") ?? false)
    }
    func testLongTableContinuesOnFollowingPagesWithoutLosingLastRow() throws {
        let rows = (1...100).map { "| Row\($0) | Some longer text here |" }.joined(separator: "\n")
        let document = try RichTextDocument("| First | Second |\n| --- | --- |\n" + rows, format: .markdown).pdf()
        XCTAssertTrue(document.pageCount > 2); XCTAssertTrue(document.string?.contains("Row100") ?? false)
    }
    func testTallTableCellSplitsAcrossPages() throws {
        let text = String(repeating: "longword ", count: 1000)
        let document = try RichTextDocument("| First | Second |\n| --- | --- |\n| \(text)FINISH | tail |", format: .markdown).pdf()
        XCTAssertTrue(document.pageCount > 1); XCTAssertTrue(document.string?.contains("FINISH") ?? false)
    }
    func testLayoutOptionsAffectPDFAndWordAndRejectInvalidValues() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let options = TextLayoutOptions(fontName: "PingFang SC", fontSize: 18, lineHeight: 1.8, margin: 90)
        let document = try RichTextDocument("body text", format: .plain, options: options)
        let file = root.appendingPathComponent("layout.docx"); try RichTextWord.write(document, to: file)
        let content = try xml(file); XCTAssertTrue(content.contains("w:top=\"1800\"")); XCTAssertTrue(content.contains("w:line=\"432\"")); XCTAssertTrue(content.contains("w:val=\"36\""))
        XCTAssertTrue(try document.pdf().pageCount == 1)
        XCTAssertThrowsError(try RichTextDocument("text", format: .plain, options: TextLayoutOptions(fontSize: .nan)))
    }
    func testMissingAndRemoteImagesFailClearlyWithoutWritingDestination() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.docx"); try Data("keep".utf8).write(to: file)
        XCTAssertThrowsError(try TextFileExport.writeWord("![x](missing.png)", format: .markdown, to: file, baseURL: root))
        XCTAssertEqual(try String(contentsOf: file), "keep")
        XCTAssertThrowsError(try RichTextDocument("<img src='https://example.com/image.png'>", format: .html))
    }
    @MainActor func testInsertedImageRemainsAvailableAfterSaveAsAndReopen() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let note = MarkdownNote(storage: root); try note.insertImageData(png())
        let first = root.appendingPathComponent("first/note.md"); try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.write(to: first); XCTAssertFalse(note.text.contains("file://")); XCTAssertTrue(note.text.contains("note-assets/"))
        let second = root.appendingPathComponent("second/copied.md"); try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.write(to: second); try FileManager.default.removeItem(at: first.deletingLastPathComponent())
        let reopened = try MarkdownNote.open(second, storage: root); XCTAssertEqual(try reopened.renderDocument().pageCount, 1)
        XCTAssertTrue(reopened.text.contains("copied-assets/"))
    }
    @MainActor func testHTMLInsertedImageAndNoteBackupSurviveRestore() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let note = MarkdownNote(storage: root, format: .html); try note.insertImageData(png()); try note.writeBackup()
        let restored = try XCTUnwrap(MarkdownNote.restoreBackups(storage: root).first)
        XCTAssertEqual(restored.format, .html); XCTAssertEqual(try restored.renderDocument().pageCount, 1)
        try restored.write(to: root.appendingPathComponent("a b.html")); XCTAssertTrue(restored.text.contains("a%20b-assets/"))
    }
    func testTablePipeEscapingAndCodeDoNotCreateExtraCells() {
        XCTAssertEqual(RichTextDocument.tableCells("| a\\|b | `x|y` |"), ["a|b", "`x|y`"])
    }
    func testToolbarPinnedActionsCannotBeHiddenAndOrderPersists() {
        var preferences = ToolbarPreferences(); preferences.hidden = Set(ToolbarAction.allCases); preferences.move(.print, by: -1)
        let decoded = ToolbarPreferences.decode(preferences.encoded)
        XCTAssertTrue(decoded.visible.contains(.annotate)); XCTAssertTrue(decoded.visible.contains(.tools)); XCTAssertFalse(decoded.visible.contains(.save))
        XCTAssertEqual(decoded.order, preferences.order); XCTAssertEqual(Set(decoded.order).count, ToolbarAction.allCases.count)
    }
    @MainActor func testPageTransferCopiesMetadataAnnotationsAndSupportsUndo() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), source = store.newPDF(), target = store.newPDF()
        source.document = DocumentServicesTests().fixture()
        source.outlineEntries = [OutlineEntry(page: 1, label: "Chapter", depth: 0)]
        source.bookmarks = [PageBookmark(page: 1, label: "Bookmark")]
        source.updateMeta(1) { $0.ocrRegions = [RecognizedLine(text: "OCR", box: .zero)] }
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil); note.contents = "keep"; source.document.page(at: 1)!.addAnnotation(note)
        source.edited()
        let drag = PageDrag(source: source.id, revision: source.revision, pages: [1])
        XCTAssertTrue(store.preparePageTransfer(drag, to: target, at: 0))
        XCTAssertTrue(store.transferPages(try XCTUnwrap(store.pendingPageTransfer), move: false)); XCTAssertEqual(source.count, 3); XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target.meta(0).ocrRegions?.first?.text, "OCR"); XCTAssertEqual(target.outlineEntries.first?.label, "Chapter"); XCTAssertEqual(target.bookmarks.first?.page, 0)
        XCTAssertTrue(target.document.page(at: 0)!.annotations.contains { $0.contents == "keep" })
        target.undo(); XCTAssertEqual(target.count, 1); target.redo(); XCTAssertEqual(target.count, 2); XCTAssertEqual(target.meta(0).ocrRegions?.first?.text, "OCR")
    }
    @MainActor func testMovingPagesProtectsLastSourcePageAndBothDocumentsUndo() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), source = store.newPDF(), target = store.newPDF()
        var drag = PageDrag(source: source.id, revision: source.revision, pages: [0]); XCTAssertTrue(store.preparePageTransfer(drag, to: target, at: 1))
        XCTAssertFalse(store.transferPages(try XCTUnwrap(store.pendingPageTransfer), move: true)); XCTAssertEqual(source.count, 1); XCTAssertEqual(target.count, 1)
        source.document = DocumentServicesTests().fixture(); source.edited()
        drag = PageDrag(source: source.id, revision: source.revision, pages: [0, 2]); XCTAssertTrue(store.preparePageTransfer(drag, to: target, at: 1))
        XCTAssertTrue(store.transferPages(try XCTUnwrap(store.pendingPageTransfer), move: true)); XCTAssertEqual(source.count, 1); XCTAssertEqual(target.count, 3)
        source.undo(); target.undo(); XCTAssertEqual(source.count, 3); XCTAssertEqual(target.count, 1)
    }
    @MainActor func testChangedSourceRejectsStalePageDrag() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), source = store.newPDF(), target = store.newPDF()
        let drag = PageDrag(source: source.id, revision: source.revision, pages: [0]); XCTAssertTrue(store.preparePageTransfer(drag, to: target, at: 0))
        let request = try XCTUnwrap(store.pendingPageTransfer); source.edited()
        XCTAssertFalse(store.transferPages(request, move: false)); XCTAssertEqual(target.count, 1)
        XCTAssertFalse(target.receivePageDrag("KongFolio:0", before: 0))
    }
    @MainActor func ocrWorkspace(_ root: URL) throws -> Workspace {
        let workspace = Workspace(storage: root), original = DocumentServicesTests().fixture()
        workspace.document = PDFDocument()
        for index in 0..<2 {
            let regions = [RecognizedLine(text: "wrong wrong", box: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.05))]
            workspace.document.insert(try DocumentServices.searchablePage(original.page(at: index)!, lines: regions), at: index)
            workspace.updateMeta(index) { $0.ocrRegions = regions; $0.ocrOriginal = DocumentServices.subset(original, indexes: [index]).dataRepresentation() }
        }
        return workspace
    }
    @MainActor func testBatchOCRSelectiveOccurrencesUpdateSearchAndUndoTogether() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try ocrWorkspace(root), expected = workspace.revision
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_QA_OUTPUT"] { try workspace.snapshot().write(URL(fileURLWithPath: path).appendingPathComponent("ocr.kongfolio")) }
        let hits = OCRBatchCorrection.matches(regions: workspace.ocrRegions, rules: [ReplacementRule(from: "wrong", to: "correct")])
        XCTAssertEqual(hits.count, 4)
        workspace.applyOCRBatch([hits[0], hits[3]], expected: expected)
        for _ in 0..<200 where workspace.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(workspace.busy); XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.meta(0).ocrRegions?.first?.text, "correct wrong"); XCTAssertEqual(workspace.meta(1).ocrRegions?.first?.text, "wrong correct")
        XCTAssertEqual(workspace.document.findString("correct", withOptions: []).count, 2)
        XCTAssertEqual(workspace.meta(0).ocrRegions?.first?.originalText, "wrong wrong")
        workspace.undo(); XCTAssertEqual(workspace.meta(0).ocrRegions?.first?.text, "wrong wrong"); XCTAssertEqual(workspace.meta(1).ocrRegions?.first?.text, "wrong wrong")
    }
    func testOCRRulesDoNotCascadeOrOverlapAndHandleUTF16() {
        let regions = [0: [RecognizedLine(text: "😀甲乙甲", box: .zero)]]
        let hits = OCRBatchCorrection.matches(regions: regions, rules: [ReplacementRule(from: "甲乙", to: "甲"), ReplacementRule(from: "甲", to: "乙")])
        XCTAssertEqual(hits.count, 2); XCTAssertEqual(hits[0].range.location, 2); XCTAssertEqual(hits[1].range.location, 4)
        XCTAssertTrue(OCRBatchCorrection.matches(regions: regions, rules: [ReplacementRule(from: "甲", to: "乙")], pages: [1]).isEmpty)
    }
    @MainActor func testOCRBatchFailureLeavesEveryPageUnchanged() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try ocrWorkspace(root)
        var archive = try workspace.snapshot(); archive.ocrOriginals?[1] = nil
        let hits = OCRBatchCorrection.matches(regions: workspace.ocrRegions, rules: [ReplacementRule(from: "wrong", to: "correct")])
        XCTAssertThrowsError(try OCRBatchCorrection.prepare(archive, hits: hits))
        XCTAssertEqual(workspace.document.findString("wrong", withOptions: []).count, 4)
    }
    @MainActor func testProjectRestartKeepsSignatureMovableAndRemovableWithUndo() throws {
        let (workspace, _, root) = try SignatureTests().placedOnce(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("signed.kongfolio"); try workspace.snapshot().write(file)
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_QA_OUTPUT"] { try workspace.snapshot().write(URL(fileURLWithPath: path).appendingPathComponent("signed.kongfolio")) }
        let restored = Workspace(storage: root); try restored.restore(ProjectArchive.read(file))
        let page = restored.document.page(at: 1)!, hit = try XCTUnwrap(restored.placedSignature(on: page, at: CGPoint(x: 85, y: 125)))
        restored.removePlacedSignature(hit.item, in: hit.layer)
        XCTAssertFalse(try SignatureTests().dark(restored, page: 1, x: 85, y: 125))
        restored.undo(); XCTAssertNotNil(restored.placedSignature(on: restored.document.page(at: 1)!, at: CGPoint(x: 85, y: 125)))
    }
    @MainActor func testSavedPDFSignatureMetadataRequiresExactBytes() throws {
        let (workspace, _, root) = try SignatureTests().placedOnce(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("signed.pdf"); try workspace.pdfData().write(to: file)
        try SignaturePersistence.write(workspace.signatureEditArchives, pdf: file, storage: root)
        XCTAssertEqual(SignaturePersistence.read(pdf: file, bytes: try Data(contentsOf: file), storage: root).count, 1)
        XCTAssertTrue(SignaturePersistence.read(pdf: file, bytes: Data("changed externally".utf8), storage: root).isEmpty)
        try SignaturePersistence.write([:], pdf: file, storage: root)
        XCTAssertTrue(SignaturePersistence.read(pdf: file, bytes: try Data(contentsOf: file), storage: root).isEmpty)
    }
    @MainActor func testSignatureReorderDuplicateAndReplacementRemainEditable() throws {
        let (workspace, _, root) = try SignatureTests().placedOnce(); defer { try? FileManager.default.removeItem(at: root) }
        workspace.rebuild(order: [1, 0, 1, 2], selected: [0])
        XCTAssertNotNil(workspace.signatureLayer(for: workspace.document.page(at: 0)!)); XCTAssertNotNil(workspace.signatureLayer(for: workspace.document.page(at: 2)!))
        let layer = try XCTUnwrap(workspace.signatureLayer(for: workspace.document.page(at: 0)!))
        try workspace.replacePlacedSignature(layer.items[0], in: layer, png: png())
        workspace.undo(); XCTAssertEqual(workspace.signatureEditArchives.count, 2)
    }
    @MainActor func testMidMoveRecoveryRetainsOriginalSignature() throws {
        let (workspace, view, root) = try SignatureTests().placedOnce(); defer { try? FileManager.default.removeItem(at: root) }
        let hit = try XCTUnwrap(workspace.placedSignature(on: workspace.document.page(at: 1)!, at: CGPoint(x: 85, y: 125)))
        workspace.beginMovingSignature(hit.item, in: hit.layer); XCTAssertNotNil(view.shown)
        let recovery = try workspace.snapshot(), restored = Workspace(storage: root); try restored.restore(recovery)
        XCTAssertNotNil(restored.placedSignature(on: restored.document.page(at: 1)!, at: CGPoint(x: 85, y: 125)))
        workspace.cancelSignaturePlacement()
    }
    @MainActor func testTransferredSignedPageKeepsEditingSource() throws {
        let (source, _, root) = try SignatureTests().placedOnce(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try source.snapshot(), subset = try PageTransferArchive.subset(archive, pages: [1])
        let restored = Workspace(storage: root); try restored.restore(subset)
        XCTAssertNotNil(restored.placedSignature(on: restored.document.page(at: 0)!, at: CGPoint(x: 85, y: 125)))
    }
}
