import XCTest
@testable import KongFolio

final class LibraryEditingTests:XCTestCase {
    func testLibraryDisplayDoesNotChangeMainEditorPreferences() throws {
        let suite = "KongFolio.libraryEditingTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var reader = EditorDisplayOptions();reader.size = 22;reader.lineHeight = 1.8
        reader.save(defaults)
        XCTAssertEqual(LibraryWritingPreferences.load(defaults).size,18)
        var library = LibraryWritingPreferences.load(defaults);library.size = 20;library.face = .serif
        LibraryWritingPreferences.save(library,to:defaults)
        XCTAssertEqual(LibraryWritingPreferences.load(defaults),library)
        XCTAssertEqual(EditorDisplayOptions.load(defaults),reader)
        library.size = .nan
        LibraryWritingPreferences.save(library,to:defaults)
        XCTAssertEqual(LibraryWritingPreferences.load(defaults).size,20)
    }
    func citation(_ path:String)->ReadingCitation {
        ReadingCitation(source:SourceRef(path:path,fileName:"测试原书.pdf",page:3),title:"测试原书")
    }
    func testBookScopeIncludesLinkedEssaysButExcludesOtherBooks() async {
        let source = citation("/生成资料/甲.pdf")
        let a = ReadingRecord(kind:.note,note:"甲书笔记",citations:[source])
        let b = ReadingRecord(kind:.note,note:"乙书笔记",citations:[citation("/生成资料/乙.pdf")])
        let essay = ReadingEssay(title:"跨书札记",blocks:[ReadingEssay.Block(text:"论述",record:a),ReadingEssay.Block(record:b)])
        let unrelated = ReadingEssay(title:"独立札记",blocks:[ReadingEssay.Block(text:"其他想法")])
        let state = ReadingJournalState(records:[a,b],essays:[essay,unrelated])
        let request = ReadingSearchRequest(revision:1,bookPath:source.source.path)
        let values = await ReadingSearchWorker.shared.library(state,request:request)
        XCTAssertEqual(Set(values.map(\.id)),[.record(a.id),.essay(essay.id)])
        let all = await ReadingSearchWorker.shared.library(state,request:ReadingSearchRequest(revision:1))
        XCTAssertEqual(all.count,4)
    }
    @MainActor func testBookNoteDraftStaysEmptyUntilInputThenReopensWithItsSource() async throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let journal = ReadingJournal(storage:folder),source = citation("/生成资料/甲.pdf")
        let draft = journal.beginLibraryRecord(.note,source:source)
        XCTAssertTrue(journal.state.records.isEmpty)
        XCTAssertEqual(journal.draftRecord?.citations,[source])
        XCTAssertTrue(journal.draftRecord?.wholeBook == true)
        journal.editRecord(draft.id) { $0.note = "第一行中文\n- 第二行列表\n" }
        XCTAssertNil(journal.draftRecord)
        try await journal.flush()
        let reopened = ReadingJournal(storage:folder)
        XCTAssertEqual(reopened.record(draft.id)?.note,"第一行中文\n- 第二行列表\n")
        XCTAssertEqual(reopened.record(draft.id)?.citations,[source])
        XCTAssertEqual(reopened.state.records.count,1)
    }
    @MainActor func testBookEssayDraftHasSourceWithoutCreatingAnEmptyEntry() async throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let journal = ReadingJournal(storage:folder),source = citation("/生成资料/甲.pdf")
        let id = journal.beginLibraryEssay(source:source)
        XCTAssertTrue(journal.state.essays.isEmpty)
        XCTAssertFalse(journal.essay(id)?.hasContent ?? true)
        XCTAssertTrue(journal.essay(id)?.blocks.first?.record?.wholeBook == true)
        journal.editEssay(id) { $0.blocks[0].text = "这本书引出的思考" }
        try await journal.flush()
        let reopened = ReadingJournal(storage:folder)
        XCTAssertTrue(ReadingLibraryItem.essay(try XCTUnwrap(reopened.essay(id))).isFromBook(source.source.path))
        XCTAssertEqual(reopened.essay(id)?.blocks[0].text,"这本书引出的思考")
        XCTAssertEqual(reopened.essay(id)?.blocks[0].record?.citations,[source])
        XCTAssertTrue(reopened.state.records.isEmpty)
    }
    func testBookScopeCombinesWithRemovedTagsAndTextFilters() async {
        var live = ReadingRecord(kind:.note,note:"待整理内容",citations:[citation("/生成资料/甲.pdf")],tags:["史料"])
        var removed = live;removed.id = UUID();removed.removed = Date()
        let foreign = ReadingRecord(kind:.note,note:live.note,citations:[citation("/生成资料/乙.pdf")],tags:live.tags)
        let state = ReadingJournalState(records:[live,removed,foreign])
        var request = ReadingSearchRequest(revision:1,query:"待整理",tag:"史料",bookPath:"/生成资料/甲.pdf")
        let active = await ReadingSearchWorker.shared.library(state,request:request)
        XCTAssertEqual(active.map(\.id),[.record(live.id)])
        request.removed = true
        let deleted = await ReadingSearchWorker.shared.library(state,request:request)
        XCTAssertEqual(deleted.map(\.id),[.record(removed.id)])
        request.tag = "其他标签"
        let empty = await ReadingSearchWorker.shared.library(state,request:request)
        XCTAssertTrue(empty.isEmpty)
        live.note = "局部变量变化不应修改冻结的状态"
        XCTAssertEqual(state.records[0].note,"待整理内容")
    }
}
