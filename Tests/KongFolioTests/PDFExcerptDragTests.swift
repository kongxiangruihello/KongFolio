import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import KongFolio

final class PDFExcerptDragTests: XCTestCase {
    @MainActor private func selectedText(_ store: WorkspaceStore, folder: URL) throws -> (Workspace,PDFSelection,Data) {
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let file = try PDFTextSnapshot053Tests().fixture(folder)
        let bytes = try Data(contentsOf:file)
        workspace.load([file],prepared:.documents([bytes]))
        let first = try XCTUnwrap(workspace.document.page(at:0))
        let second = try XCTUnwrap(workspace.document.page(at:1))
        let selection = try XCTUnwrap(first.selection(for:NSRange(location:0,length:8)))
        selection.add(try XCTUnwrap(second.selection(for:NSRange(location:0,length:8))))
        return (workspace,selection,bytes)
    }

    @MainActor func testPDFDragSavesOneExcerptWithBothPagePositionsOnlyOnDrop() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        let (workspace,selection,bytes) = try selectedText(store,folder:root)
        store.showReadingPanel(.excerpts)
        let record = try XCTUnwrap(workspace.readingExcerpt(from:selection))
        let drag = try XCTUnwrap(store.beginPDFExcerptDrag(record,from:workspace))
        XCTAssertTrue(store.journal.state.records.isEmpty)
        let item = drag.pasteboardItem()
        let type = NSPasteboard.PasteboardType(UTType.kongFolioPDFExcerpt.identifier)
        let data = try XCTUnwrap(item.data(forType:type))
        let token = try XCTUnwrap(UUID(uuidString:String(decoding:data,as:UTF8.self)))
        XCTAssertEqual(item.string(forType:.string),record.quote)
        XCTAssertFalse(store.acceptPDFExcerptDrop(UUID()))
        XCTAssertTrue(store.acceptPDFExcerptDrop(token))
        XCTAssertFalse(store.acceptPDFExcerptDrop(token))
        let excerpt = try XCTUnwrap(store.journal.record(store.readingRecordID))
        XCTAssertEqual(excerpt.kind,.excerpt)
        XCTAssertEqual(excerpt.quote,record.quote)
        XCTAssertEqual(excerpt.citations.map(\.source.page),[0,1])
        XCTAssertTrue(excerpt.citations.allSatisfy { !$0.source.rects.isEmpty && $0.tracking != nil })
        XCTAssertEqual(store.journal.state.records.count,1)
        XCTAssertEqual(try Data(contentsOf:try XCTUnwrap(workspace.sourceURL)),bytes)
    }

    @MainActor func testCancelledOrMisplacedDragDoesNotCreateAnExcerpt() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        let (workspace,selection,_) = try selectedText(store,folder:root)
        let record = try XCTUnwrap(workspace.readingExcerpt(from:selection))
        XCTAssertNil(store.beginPDFExcerptDrag(record,from:workspace))
        store.showReadingPanel(.excerpts)
        let first = try XCTUnwrap(store.beginPDFExcerptDrag(record,from:workspace))
        store.cancelPDFExcerptDrag(first.token)
        XCTAssertFalse(store.acceptPDFExcerptDrop(first.token))
        let second = try XCTUnwrap(store.beginPDFExcerptDrag(record,from:workspace))
        store.showReadingPanel(.notes)
        XCTAssertFalse(store.acceptPDFExcerptDrop(second.token))
        store.showReadingPanel(.excerpts)
        XCTAssertFalse(store.acceptPDFExcerptDrop(second.token))
        XCTAssertTrue(store.journal.state.records.isEmpty)
    }
}
