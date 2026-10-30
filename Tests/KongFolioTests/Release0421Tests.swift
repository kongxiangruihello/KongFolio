import XCTest
@testable import KongFolio

final class Release0421Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func note() -> ReadingRecord { ReadingRecord(kind:.note,citations:[ReadingCitation(source:SourceRef(path:"/史料.pdf",fileName:"史料.pdf",page:7),title:"史料")]) }
    @MainActor func testBlankNoteNeverCreatesCatalogOrLastNotePointer() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), empty = note()
        journal.beginNote(empty); try await journal.flush()
        XCTAssertEqual(journal.record(empty.id)?.id,empty.id); XCTAssertTrue(journal.state.records.isEmpty); XCTAssertTrue(journal.state.lastNotes.isEmpty)
        XCTAssertFalse(journal.dirty); XCTAssertFalse(FileManager.default.fileExists(atPath:journal.folder.appendingPathComponent("catalog.json").path))
        XCTAssertNil(ReadingJournal(storage:root).record(empty.id))
    }
    @MainActor func testRepeatedNewAndWhitespaceOnlyNotesRemainOneTransientDraft() async throws {
        let journal = ReadingJournal(storage:try root())
        for _ in 0..<20 { journal.add(note()) }
        let id = try XCTUnwrap(journal.draftRecord?.id)
        journal.editRecord(id) { $0.note = " \n\t　"; $0.title = " \n"; $0.tags = [" "] }
        try await journal.flush(); XCTAssertTrue(journal.state.records.isEmpty); XCTAssertEqual(journal.draftRecord?.id,id); XCTAssertFalse(journal.dirty)
        journal.discardNoteDraft(); XCTAssertNil(journal.record(id))
    }
    @MainActor func testFirstNoteInputPersistsExactlyOnceWithItsSourceAndLatestText() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), empty = note(); journal.beginNote(empty)
        journal.editRecord(empty.id) { $0.note = "第一段" }; journal.editRecord(empty.id) { $0.note += "\n最后的思考" }; try await journal.flush()
        XCTAssertNil(journal.draftRecord); XCTAssertEqual(journal.state.records.count,1)
        let reopened = ReadingJournal(storage:root); XCTAssertEqual(reopened.record(empty.id)?.note,"第一段\n最后的思考"); XCTAssertEqual(reopened.record(empty.id)?.citations,empty.citations); XCTAssertEqual(reopened.state.lastNotes["/史料.pdf"],empty.id)
    }
    @MainActor func testCreatingDraftDoesNotReplaceThePreviousBookNote() async throws {
        let root = try root(), journal = ReadingJournal(storage:root); var old = note(); old.note = "已经写好的笔记"; journal.add(old); try await journal.flush()
        journal.beginNote(note()); try await journal.flush()
        XCTAssertEqual(ReadingJournal(storage:root).state.lastNotes["/史料.pdf"],old.id); XCTAssertEqual(journal.state.records.count,1)
    }
    @MainActor func testWholeBookDefaultHeadingIsNotContentButOwnTitleIsSaved() async throws {
        let journal = ReadingJournal(storage:try root()); var empty = note(); empty.wholeBook = true; empty.title = "整本书心得"; journal.beginNote(empty)
        journal.editRecord(empty.id) { $0.note = " \n" }; try await journal.flush(); XCTAssertTrue(journal.state.records.isEmpty)
        journal.editRecord(empty.id) { $0.title = "关于教育思想的观察" }; try await journal.flush(); XCTAssertEqual(journal.state.records.count,1); XCTAssertTrue(try XCTUnwrap(journal.record(empty.id)).wholeBook)
    }
    @MainActor func testStoreNewNoteWithoutAnOpenBookStaysADraft() async throws {
        let store = WorkspaceStore(storage:try root()); store.newReadingNote(); let first = try XCTUnwrap(store.readingRecordID); store.newReadingNote(); let second = try XCTUnwrap(store.readingRecordID)
        XCTAssertFalse(first == second); XCTAssertNil(store.journal.record(first)); XCTAssertEqual(store.journal.draftRecord?.id,second); try await store.journal.flush(); XCTAssertTrue(store.journal.state.records.isEmpty)
    }
    @MainActor func testEmptyEssayAndEmptyParagraphsNeverCreateSavedEssays() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), id = journal.newEssay()
        journal.editEssay(id) { $0.blocks.append(ReadingEssay.Block()); $0.blocks[0].text = " \n" }; try await journal.flush()
        XCTAssertEqual(journal.currentEssayID,id); XCTAssertNil(journal.state.currentEssay); XCTAssertTrue(journal.state.essays.isEmpty); XCTAssertFalse(journal.dirty); XCTAssertTrue(ReadingJournal(storage:root).state.essays.isEmpty)
    }
    @MainActor func testEssayFirstTextAndFrozenReferenceAreSaved() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), id = journal.newEssay()
        journal.editEssay(id) { $0.blocks[0].text = "我的论述" }; var ref = note(); ref.note = "引用的笔记"; journal.insert(ref,in:id); try await journal.flush()
        XCTAssertNil(journal.draftEssay); let reopened = ReadingJournal(storage:root); XCTAssertEqual(reopened.state.essays.count,1); XCTAssertEqual(reopened.currentEssayID,id); XCTAssertEqual(reopened.essay(id)?.blocks.first?.text,"我的论述"); XCTAssertEqual(reopened.essay(id)?.blocks.last?.record,ref)
    }
    @MainActor func testSelectingSavedEssayDiscardsOnlyEmptyEssayDraft() async throws {
        let journal = ReadingJournal(storage:try root()), saved = journal.newEssay(title:"已保存的札记"), draft = journal.newEssay()
        journal.selectEssay(saved); XCTAssertNil(journal.essay(draft)); XCTAssertEqual(journal.currentEssayID,saved); try await journal.flush(); XCTAssertEqual(journal.state.essays.count,1)
    }
    func testLegacyEmptyRowsCanBeHiddenWithoutDestroyingStoredData() throws {
        let empty = note(); var content = empty; content.id = UUID(); content.note = "旧笔记"; let image = ReadingRecord(kind:.image,imageAsset:"scan.png")
        let state = ReadingJournalState(records:[empty,content,image],essays:[ReadingEssay(),ReadingEssay(title:"实际札记")])
        let roundTrip = try JSONDecoder().decode(ReadingJournalState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(roundTrip.records.count,3); XCTAssertEqual(roundTrip.records.filter(\.hasContent).map(\.id),[content.id,image.id]); XCTAssertEqual(roundTrip.essays.filter(\.hasContent).count,1)
    }
    func testEveryRecordAppearsExactlyOnceAcrossAllPages() {
        for size in [10,20,50] {
            let values = Array(0..<113); let last = ReadingPagination(total:values.count,page:0,size:size).last
            let pages = (0...last).flatMap { page -> [Int] in let p = ReadingPagination(total:values.count,page:page,size:size); return Array(values[p.range]) }
            XCTAssertEqual(pages,values); XCTAssertEqual(Set(pages).count,values.count)
        }
    }
    func testPaginationClampsAfterFilteringDeletingAndChangingPageSize() {
        let empty = ReadingPagination(total:0,page:9,size:10); XCTAssertEqual(empty.index,0); XCTAssertTrue(empty.range.isEmpty); XCTAssertEqual(empty.label,"第 1 / 1 页")
        let filtered = ReadingPagination(total:3,page:8,size:10); XCTAssertEqual(filtered.range,0..<3); XCTAssertEqual(filtered.index,0)
        let resized = ReadingPagination(total:21,page:2,size:20); XCTAssertEqual(resized.index,1); XCTAssertEqual(resized.range,20..<21)
        XCTAssertEqual(ReadingPagination(total:10,page:1,size:10).index,0); XCTAssertEqual(ReadingPagination(total:11,page:1,size:10).range,10..<11)
        XCTAssertEqual(ReadingPagination(total:11,page:-9,size:0).size,10); XCTAssertEqual(ReadingPagination(total:11,page:-9,size:10).index,0)
    }
}
