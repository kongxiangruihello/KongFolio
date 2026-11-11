import XCTest
import PDFKit
@testable import KongFolio

@MainActor final class SearchSeparation0531Tests: XCTestCase {
    func testEmptyAndTextTabsCannotRedirectPDFSearchToLibrary() throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=WorkspaceStore(storage:root);store.bootstrap()
        XCTAssertFalse(store.canSearchPDF);XCTAssertFalse(store.openPDFSearch())
        XCTAssertFalse(store.showReadingDesk);XCTAssertNil(store.readingDeskWindowRequest)
        _=store.newNote();XCTAssertFalse(store.canSearchPDF);XCTAssertFalse(store.openPDFSearch())
        XCTAssertFalse(store.showReadingDesk);XCTAssertNil(store.readingDeskWindowRequest)
    }
    func testPDFSearchUsesDocumentTextAndRefocusesWithoutOpeningLibrary() throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=WorkspaceStore(storage:root);store.bootstrap();let w=try XCTUnwrap(store.activeWorkspace)
        let file=try PDFTextSnapshot053Tests().fixture(root);w.load([file],prepared:.documents([try Data(contentsOf:file)]))
        store.journal.add(ReadingRecord(kind:.note,note:"OnlyInLibrary0531"))
        w.sidebarTab = .bookmarks
        w.pageEditing053 = true
        store.showReadingPanel(.excerpts)
        let first = w.pdfSearchFocusRequest
        XCTAssertTrue(store.openPDFSearch())
        XCTAssertTrue(store.rightPDFSearchWorkspace === w)
        XCTAssertEqual(w.sidebarTab,.bookmarks)
        XCTAssertTrue(w.pageEditing053)
        XCTAssertFalse(first==w.pdfSearchFocusRequest);let second=w.pdfSearchFocusRequest
        XCTAssertTrue(store.openPDFSearch());XCTAssertFalse(second==w.pdfSearchFocusRequest)
        XCTAssertFalse(store.showReadingDesk);XCTAssertNil(store.readingDeskWindowRequest)
        let bytes=try w.pdfData()
        XCTAssertEqual(try ReadingServices.search(bytes,query:"FindPage2Only").map(\.page),[1])
        XCTAssertTrue(try ReadingServices.search(bytes,query:"OnlyInLibrary0531").isEmpty)
    }
    func testPDFSearchFollowsFocusedPane() throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=WorkspaceStore(storage:root);store.bootstrap();let first=try XCTUnwrap(store.activeWorkspace),second=store.addWorkspace()
        let file=try Release046Tests().pdf(root,pages:2),data=try Data(contentsOf:file)
        first.load([file],prepared:.documents([data]));second.load([file],prepared:.documents([data]))
        store.select(first.id);first.splitPartner=second;store.focus(second)
        XCTAssertTrue(store.openPDFSearch())
        XCTAssertTrue(store.rightPDFSearchWorkspace === second)
        XCTAssertNil(store.readingDeskWindowRequest)
        store.showReadingPanel(.notes)
        XCTAssertNil(store.rightPDFSearchWorkspace)
        XCTAssertTrue(store.showReadingDesk)
        store.closeRightReadingPanel()
        XCTAssertFalse(store.showReadingDesk)
    }
    func testNewNoteOpensRightEditorAndOnlyPersistsAfterWriting() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let file = try PDFTextSnapshot053Tests().fixture(root)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        XCTAssertTrue(store.openPDFSearch())

        store.newReadingNote()
        let draft = try XCTUnwrap(store.journal.draftRecord)
        XCTAssertEqual(store.readingRecordID,draft.id)
        XCTAssertEqual(store.readingDeskSection,.notes)
        XCTAssertTrue(store.showReadingDesk)
        XCTAssertNil(store.rightPDFSearchWorkspace)
        XCTAssertNil(store.readingDeskWindowRequest)
        XCTAssertTrue(store.journal.state.records.isEmpty)
        XCTAssertEqual(draft.citations.first?.source.page,workspace.selection)

        store.openReadingDesk(.search,window:true)
        XCTAssertEqual(store.readingDeskSection,.notes)
        XCTAssertEqual(store.readingDeskWindowSection,.search)
        store.journal.editRecord(draft.id) { $0.note = "读书笔记" }
        XCTAssertNil(store.journal.draftRecord)
        XCTAssertEqual(store.journal.state.records.first?.note,"读书笔记")
        XCTAssertEqual(store.journal.state.records.first?.citations,draft.citations)
    }
    func testLibrarySearchFindsAllRecordKindsAndRespectsVisibleScope() async {
        let origin=ReadingPDFOrigin(annotationID:"generated",type:"批注",contents:"海关评论",originalCreated:nil,originalModified:nil)
        let excerpt=ReadingRecord(kind:.excerpt,quote:"海关摘录"),mark=ReadingRecord(kind:.annotation,quote:"海关标注"),comment=ReadingRecord(kind:.comment,pdfOrigin:origin),note=ReadingRecord(kind:.note,note:"海关笔记")
        let state=ReadingJournalState(records:[excerpt,mark,comment,note]);var options=ReadingLibraryOptions053()
        var found=await ReadingSearchWorker.shared.library(state,request:ReadingSearchRequest(revision:1,query:"海关",options053:options));XCTAssertEqual(Set(found.map(\.id)),Set(state.records.map{ReadingLibraryID.record($0.id)}))
        options.scope = .mine;found=await ReadingSearchWorker.shared.library(state,request:ReadingSearchRequest(revision:1,query:"海关",options053:options));XCTAssertEqual(found.map(\.id),[.record(note.id)])
        options.scope = .quote;found=await ReadingSearchWorker.shared.library(state,request:ReadingSearchRequest(revision:1,query:"海关",options053:options));XCTAssertEqual(Set(found.map(\.id)),Set([.record(excerpt.id),.record(mark.id)]))
        options.scope = .comment;found=await ReadingSearchWorker.shared.library(state,request:ReadingSearchRequest(revision:1,query:"海关",options053:options));XCTAssertEqual(found.map(\.id),[.record(comment.id)])
    }
}
