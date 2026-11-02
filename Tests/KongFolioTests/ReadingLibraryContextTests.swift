import XCTest
@testable import KongFolio

final class ReadingLibraryContextTests:XCTestCase {
    func record(_ text:String) -> ReadingRecord { ReadingRecord(kind:.note,note:text) }
    func testContextTargetsDoNotFallBackToUnrelatedSelection() {
        let a=record("原先选中的笔记"),b=record("实际右键的笔记"),state=ReadingJournalState(records:[a,b])
        let scope=ReadingLibraryContext.resolve([.record(b.id)],state:state,removed:false)
        XCTAssertEqual(scope.ids,[.record(b.id)]);XCTAssertFalse(scope.clipboardText().contains(a.note));XCTAssertTrue(scope.clipboardText().contains(b.note))
        XCTAssertTrue(ReadingLibraryContext.resolve([.record(UUID())],state:state,removed:false).items.isEmpty)
    }
    func testMixedMultiSelectionHasStableListOrderAndNoAppendToEssay() {
        var a=record("甲"),b=record("乙");a.created=Date(timeIntervalSinceReferenceDate:1);b.created=Date(timeIntervalSinceReferenceDate:2);let essay=ReadingEssay(title:"札记",created:Date(timeIntervalSinceReferenceDate:3)),state=ReadingJournalState(records:[a,b],essays:[essay])
        let scope=ReadingLibraryContext.resolve([.record(a.id),.essay(essay.id)],state:state,removed:false)
        XCTAssertEqual(scope.items.map(\.id),[.essay(essay.id),.record(a.id)]);XCTAssertFalse(scope.canAppend);XCTAssertNil(scope.single)
    }
    func testDeletedAndEmptyRecordsAreResolvedOnlyInTheirOwnScope() {
        let a=record("正文");var deleted=record("移除的内容");deleted.removed=Date();let empty=ReadingRecord(kind:.note),state=ReadingJournalState(records:[a,deleted,empty]),ids:Set<ReadingLibraryID>=[.record(a.id),.record(deleted.id),.record(empty.id)]
        XCTAssertEqual(ReadingLibraryContext.resolve(ids,state:state,removed:false).ids,[.record(a.id)])
        let scope=ReadingLibraryContext.resolve(ids,state:state,removed:true);XCTAssertEqual(scope.ids,[.record(deleted.id)]);XCTAssertFalse(scope.canAppend);XCTAssertTrue(scope.clipboardText().contains(deleted.note))
        XCTAssertTrue(ReadingLibraryContext.resolve([],state:state,removed:false).items.isEmpty)
    }
    @MainActor func testPendingDeleteAndRestoreUseFrozenTargetsAndSupportUndo() throws {
        let journal=ReadingJournal(storage:try Release027Tests().folder()),a=record("甲笔记"),b=record("乙笔记");journal.add(a);journal.add(b)
        var selection:Set<ReadingLibraryID>=[.record(a.id)];let request=ReadingLibraryContextRequest(kind:.remove,ids:selection,removed:false);selection=[.record(b.id)]
        journal.setRemoved(request.ids,removed:!request.removed);XCTAssertNotNil(journal.record(a.id)?.removed);XCTAssertNil(journal.record(b.id)?.removed)
        try journal.undoBulk();XCTAssertNil(journal.record(a.id)?.removed)
        journal.setRemoved(request.ids,removed:true);let restore=ReadingLibraryContextRequest(kind:.remove,ids:request.ids,removed:true);journal.setRemoved(restore.ids,removed:!restore.removed);XCTAssertNil(journal.record(a.id)?.removed)
    }
    func testClipboardPreservesFullTextFrozenEssayCitationsAndImageNotice() {
        let source=SourceRef(path:"/测试原书.pdf",fileName:"测试原书.pdf",page:6,pageLabel:"一二"),citation=ReadingCitation(source:source,title:"测试书",author:"作者",edition:"初版本")
        let text=String(repeating:"完整中文原文\n",count:80),r=ReadingRecord(kind:.image,title:"图片摘录",quote:text,note:"我的评论",citations:[citation],imageAsset:"image.png"),essay=ReadingEssay(title:"我的札记",blocks:[ReadingEssay.Block(text:"独立论述",record:r)])
        let scope=ReadingLibraryContext.resolve([.record(r.id),.essay(essay.id)],state:ReadingJournalState(records:[r],essays:[essay]),removed:false),copy=scope.clipboardText()
        XCTAssertTrue(copy.contains(text));XCTAssertTrue(copy.contains("我的评论"));XCTAssertTrue(copy.contains("独立论述"));XCTAssertTrue(copy.contains("初版本"));XCTAssertTrue(copy.contains("PDF 第 7 页"));XCTAssertTrue(copy.contains("kongfolio://source"));XCTAssertTrue(copy.contains("导出文件可保留图片"));XCTAssertFalse(copy.contains("/image.png"))
    }
    func testSourceMenuDeduplicatesPositionsAndLimitsLongEssays() {
        let sources=(0..<20).map{ReadingCitation(source:SourceRef(path:"/书.pdf",fileName:"书",page:$0),title:"书")}
        let r=ReadingRecord(kind:.excerpt,quote:"摘录",citations:[sources[0]]+sources),e=ReadingEssay(title:"长札记",blocks:[ReadingEssay.Block(record:r),ReadingEssay.Block(record:r)])
        let scope=ReadingLibraryContext.resolve([.essay(e.id)],state:ReadingJournalState(essays:[e]),removed:false)
        XCTAssertEqual(scope.sources().map{$0.source.page},Array(0..<10));XCTAssertTrue(scope.sources(limit:0).isEmpty)
    }
    func testOnlyLiveRecordsCanBeInsertedAsFrozenEssayQuotes() {
        let a=record("笔记"),b=ReadingRecord(kind:.excerpt,quote:"原文"),scope=ReadingLibraryContext.resolve([.record(a.id),.record(b.id)],state:ReadingJournalState(records:[a,b]),removed:false)
        XCTAssertTrue(scope.canAppend);XCTAssertEqual(Set(scope.records.map(\.id)),[a.id,b.id])
    }
}
