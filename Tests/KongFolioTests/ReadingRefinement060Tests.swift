import AppKit
import PDFKit
import XCTest
@testable import KongFolio

final class ReadingRefinement060Tests: XCTestCase {
    @MainActor func testSelectionAppendsToCurrentUnpinnedNoteWithExactSource() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try PDFTextSnapshot053Tests().fixture(root)
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        let note = ReadingRecord(kind:.note,note:"已有正文")
        store.journal.add(note)
        store.showReadingPanel(.notes,noteID:note.id)
        XCTAssertNil(store.pinnedReadingID)
        let selection = try XCTUnwrap(workspace.document.findString("FindPage2Only").first)
        XCTAssertTrue(store.insertPDFSelectionInNote(from:workspace,selection:selection))
        let updated = try XCTUnwrap(store.journal.record(note.id))
        XCTAssertTrue(updated.note.hasPrefix("已有正文"))
        XCTAssertTrue(updated.note.contains("FindPage2Only"))
        XCTAssertEqual(updated.citations.first?.source.page,1)
        XCTAssertFalse(updated.citations.first?.source.rects.isEmpty ?? true)
        XCTAssertEqual(store.writingSearchHit?.range.location,updated.note.utf16.count)
    }

    @MainActor func testReorderedPDFCitationSurvivesWritingUndoAndExport() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try PDFTextSnapshot053Tests().fixture(root)
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        let selection = try XCTUnwrap(workspace.document.findString("FindPage2Only").first)
        let note = ReadingRecord(kind:.note,note:"已有正文")
        store.journal.add(note)
        store.showReadingPanel(.notes,noteID:note.id)
        XCTAssertTrue(store.insertPDFSelectionInNote(from:workspace,selection:selection))
        workspace.checkpoint()
        workspace.rebuild(order:[1,0],selected:[0])
        store.journal.editRecord(note.id) { $0.note += "继续写作" }
        let updated = try XCTUnwrap(store.journal.record(note.id))
        XCTAssertEqual(updated.citations.map(\.source.page),[0])
        XCTAssertEqual(updated.inlineNoteCitations?.map(\.citation.source.page),[0])

        let exported = ReadingRecordExport.exportedNote(updated.note,sources:true,citations:updated.inlineNoteCitations ?? [])
        let newLink = try XCTUnwrap(updated.citations.first.flatMap { SourceLink.url($0.source) })
        XCTAssertTrue(exported.contains(newLink.absoluteString))
        let oldLink = try XCTUnwrap(updated.inlineNoteCitations?.first?.link)
        XCTAssertFalse(exported.contains(oldLink))
        var options = ReadingExportOptions()
        options.includeSources = false
        let snapshot = ReadingExportSnapshot(title:"导出",records:[updated],options:options)
        let markdown = ReadingRecordExport.markdown(snapshot,imageFolder:"Assets")
        XCTAssertTrue(markdown.contains("FindPage2Only"))
        XCTAssertTrue(markdown.contains("继续写作"))
        XCTAssertFalse(markdown.contains("kongfolio://source"))
        XCTAssertFalse(markdown.contains("返回原文"))
        workspace.undo()
        XCTAssertEqual(store.journal.record(note.id)?.citations.map(\.source.page),[1])
        workspace.redo()
        XCTAssertEqual(store.journal.record(note.id)?.inlineNoteCitations?.map(\.citation.source.page),[0])
        try await store.journal.flush()
    }

    @MainActor func testOutputReviewFindsAndRepairsFrozenQuotationSource() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let missing = ReadingCitation(source:SourceRef(path:root.appendingPathComponent("moved.pdf").path,fileName:"原书.pdf",page:0),title:"原书")
        let excerpt = ReadingRecord(kind:.excerpt,quote:"引文",citations:[missing])
        let note = ReadingRecord(kind:.note,note:"正文",extras:ReadingRecordExtras053(quotations:excerpt.frozenExcerptParts))
        let journal = ReadingJournal(storage:root)
        journal.add(note)
        let snapshot = ReadingExportSnapshot(title:"核对",records:[note])
        let issues = try await ReadingOutputReview.shared.inspect(snapshot,assets:root)
        let target = try XCTUnwrap(issues.first { $0.message.contains("原文链接失效") }?.source)
        let pdf = try PDFTextSnapshot053Tests().fixture(root)
        var repaired = missing
        repaired.source.path = pdf.path
        try target.apply(repaired,replacing:missing,in:journal)
        XCTAssertEqual(journal.record(note.id)?.extras?.quotations?.first?.citations,[repaired])
        XCTAssertEqual(journal.record(note.id)?.citations,[])
        try await journal.flush()
    }

    @MainActor func testHiddenUnpinnedNoteIsNotAnInsertionTarget() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        let note = ReadingRecord(kind:.note,note:"先前的笔记")
        store.journal.add(note)
        store.showReadingPanel(.notes,noteID:note.id)
        XCTAssertEqual(store.citationNoteTarget?.id,note.id)
        store.closeRightReadingPanel()
        XCTAssertNil(store.citationNoteTarget)
        store.pinnedReadingID = note.id
        XCTAssertEqual(store.citationNoteTarget?.id,note.id)
    }

    @MainActor func testChangingPDFSearchCancelsOldStatus() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try PDFTextSnapshot053Tests().fixture(root)
        let workspace = Workspace(storage:root)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        workspace.search = "旧关键词"
        workspace.startSearch()
        workspace.search = "FindPage2Only"
        XCTAssertNil(workspace.searchTask)
        XCTAssertEqual(workspace.searchMessage,"")
        workspace.startSearch()
        for _ in 0..<100 where workspace.searchTask != nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNil(workspace.searchTask)
        XCTAssertEqual(workspace.searchResults.map(\.page),[1])
    }

    @MainActor func testBackupVerificationUsesIsolatedCatalogAndChecksSource() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let image = NSImage(size:NSSize(width:16,height:16),flipped:false) { bounds in
            NSColor.black.setFill()
            bounds.fill()
            return true
        }
        let png = try XCTUnwrap(SignatureImage.pngData(try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))))
        let citation = ReadingCitation(source:SourceRef(path:root.appendingPathComponent("missing.pdf").path,fileName:"missing.pdf",page:0),title:"原书")
        journal.add(ReadingRecord(kind:.image,citations:[citation]),image:png)
        journal.add(ReadingRecord(kind:.note,note:"待核对笔记"))
        let backup = try await journal.makeBackup()
        let live = journal.state
        let verified = try ReadingBackupStorage.verifyRestore(backup.id,folder:journal.folder)
        XCTAssertEqual(verified.excerpts,1)
        XCTAssertEqual(verified.notes,1)
        XCTAssertEqual(verified.images,1)
        XCTAssertEqual(verified.missingLinks,1)
        XCTAssertEqual(journal.state,live)
    }

    @MainActor func testReturnToExcerptSelectsThatRecordAmongSamePageExcerpts() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try PDFTextSnapshot053Tests().fixture(root)
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        let first = workspace.readingCitation(page:1,rects:[CGRect(x:15,y:20,width:40,height:10)])
        let second = workspace.readingCitation(page:1,rects:[CGRect(x:15,y:50,width:40,height:10)])
        let a = ReadingRecord(kind:.excerpt,quote:"第一段",citations:[first])
        let b = ReadingRecord(kind:.excerpt,quote:"第二段",citations:[second])
        store.journal.add(a)
        store.journal.add(b)
        let navigator = ReadingSourceNavigator()
        navigator.open(first,record:a,store:store)
        XCTAssertEqual(workspace.selection,1)
        XCTAssertEqual(store.readingExcerptFeedback?.recordID,a.id)
        navigator.open(second,record:b,store:store)
        XCTAssertEqual(store.readingDeskSection,.excerpts)
        XCTAssertEqual(store.readingExcerptFeedback?.recordID,b.id)
        XCTAssertEqual(store.readingRecordID,b.id)
    }

    @MainActor func testSourceAnchorFindsRecordedPageAndMissingTextKeepsPage() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try PDFTextSnapshot053Tests().fixture(root)
        let workspace = Workspace(storage:root)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        let located = try XCTUnwrap(workspace.locate(anchor:"FindPage2Only",near:1))
        XCTAssertEqual(located.page,1)
        XCTAssertFalse(located.rects.isEmpty)
        workspace.go(to:ViewPosition(selection:1),anchor:"不存在的句子")
        XCTAssertEqual(workspace.selection,1)
    }

    func testInlineCitationSurvivesOtherCopiesAndReturnsOnRedo() throws {
        let base = ReadingCitation(source:SourceRef(path:"/tmp/a.pdf",fileName:"a.pdf",page:2),title:"原有出处")
        let inserted = ReadingCitation(source:SourceRef(path:"/tmp/b.pdf",fileName:"b.pdf",page:3,rects:[CGRect(x:1,y:2,width:3,height:4)]),title:"插入出处")
        let block = ReadingNoteCitationInsertion.markdown(ReadingRecord(kind:.excerpt,quote:"史料",citations:[inserted]))
        var note = ReadingRecord(kind:.note,note:"笔记"+block+block,citations:[base])
        note.registerInlineNoteCitations([inserted])
        XCTAssertEqual(note.citations,[base,inserted])
        note.note = "笔记"+block
        note.syncInlineNoteCitations()
        XCTAssertEqual(note.citations,[base,inserted])
        note.note = "笔记"
        note.syncInlineNoteCitations()
        XCTAssertEqual(note.citations,[base])
        note.note += block
        note.syncInlineNoteCitations()
        XCTAssertEqual(note.citations,[base,inserted])
        var moved = inserted
        moved.source.page = 6
        note.citations[1] = moved
        note.replaceInlineCitation(inserted,with:moved)
        note.note = "笔记"
        note.syncInlineNoteCitations()
        XCTAssertEqual(note.citations,[base])
        note.note += block
        note.syncInlineNoteCitations()
        XCTAssertEqual(note.citations,[base,moved])
    }

    @MainActor func testJournalPersistsInlineSourceChangesWithTheText() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let citation = ReadingCitation(source:SourceRef(path:"/tmp/source.pdf",fileName:"source.pdf",page:1),title:"原件")
        let quote = ReadingRecord(kind:.excerpt,quote:"原文",citations:[citation])
        let inserted = ReadingNoteCitationInsertion.markdown(quote)
        let note = ReadingRecord(kind:.note,note:"正文")
        let journal = ReadingJournal(storage:root)
        journal.add(note)
        journal.editRecord(note.id) { $0.note += inserted; $0.registerInlineNoteCitations([citation]) }
        journal.editRecord(note.id) { $0.note = note.note }
        XCTAssertTrue(journal.record(note.id)?.citations.isEmpty == true)
        XCTAssertNil(journal.state.lastNotes[citation.source.path])
        journal.editRecord(note.id) { $0.note += inserted }
        try await journal.flush()
        XCTAssertEqual(ReadingJournal(storage:root).record(note.id)?.citations,[citation])
    }

    func testPageRecordsAndCopyFormatsUseExactSourcePage() {
        let publication = ReadingPublication053(periodical:"万国公报",issue:"第三卷第九期",published:"1907")
        let a = ReadingCitation(source:SourceRef(path:"/private/tmp/a.pdf",fileName:"a.pdf",page:2,pageLabel:"十五"),title:"篇名",publication:publication)
        let note = ReadingRecord(kind:.note,note:"正文",citations:[a])
        let quote = ReadingRecord(kind:.excerpt,quote:"原文 *",citations:[a])
        let wholeBook = ReadingRecord(kind:.note,note:"整本心得",citations:[a],wholeBook:true)
        let state = ReadingJournalState(records:[note,quote,wholeBook])
        let rows = ReadingPageRecords.items(state,path:"/tmp/a.pdf",page:2)
        XCTAssertEqual(Set(rows.map(\.id)),[.record(note.id),.record(quote.id)])
        XCTAssertTrue(ReadingPageRecords.items(state,path:"/tmp/a.pdf",page:1).isEmpty)
        XCTAssertEqual(ReadingExcerptCopyFormat.text.text(quote),"原文 *")
        XCTAssertTrue(ReadingExcerptCopyFormat.citation.text(quote).contains("印刷页码 十五"))
        XCTAssertTrue(ReadingExcerptCopyFormat.markdown.text(quote).contains("第三卷第九期"))
    }

    @MainActor func testWritingPositionRestoresIndependentSelections() throws {
        let defaults = Release037Tests().suite()
        let positions = WritingPositions(defaults:defaults)
        let first = Release043Tests().input("第一条笔记")
        first.setSelectedRange(NSRange(location:2,length:1))
        positions.capture(first,key:"first")
        let second = Release043Tests().input("另一条笔记")
        second.setSelectedRange(NSRange(location:4,length:0))
        positions.capture(second,key:"second")
        positions.flush()
        let reopened = WritingPositions(defaults:defaults)
        let editor = Release043Tests().input("第一条笔记")
        reopened.restore(editor,key:"first")
        XCTAssertEqual(editor.selectedRange(),NSRange(location:2,length:1))
        reopened.restore(editor,key:"second")
        XCTAssertEqual(editor.selectedRange(),NSRange(location:4,length:0))
    }
}
