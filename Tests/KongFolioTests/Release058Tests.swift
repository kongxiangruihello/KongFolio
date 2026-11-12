import XCTest
import PDFKit
@testable import KongFolio

final class Release058Tests: XCTestCase {
    @MainActor func testBatchRemembersPositionCompletionAndFailedDocument() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let defaults = Release037Tests().suite()
        let first = try Release037Tests().pdf(root,name:"first.pdf")
        let second = try Release037Tests().pdf(root,name:"second.pdf")
        let absent = root.appendingPathComponent("moved.pdf")
        let store = WorkspaceStore(storage:root,readingDefaults:defaults)
        store.bootstrap()
        store.openEach([first,second,absent])
        let w = try XCTUnwrap(store.activeWorkspace)
        try await Release036Tests().wait(w)
        w.selectPage(2)
        w.saveReadingRecord(capture:false)
        XCTAssertEqual(ReadingOpenBatch.load(defaults)?.next?.position?.selection,2)
        store.close(w.id)
        let current = try XCTUnwrap(store.activeWorkspace)
        try await Release036Tests().wait(current)
        let missing = try XCTUnwrap(store.readingBatch?.entry(absent.path))
        store.openReadingBatchEntry(missing)
        let deadline = Date().addingTimeInterval(5)
        while store.readingBatch?.entry(absent.path)?.status != .failed,Date() < deadline {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertEqual(store.readingBatch?.entry(absent.path)?.status,.failed)
        XCTAssertTrue(store.readingBatch?.entry(absent.path)?.message?.contains("重新定位") == true)
        let reopened = WorkspaceStore(storage:root,readingDefaults:defaults)
        XCTAssertEqual(reopened.readingBatch?.entry(first.path)?.status,.finished)
        XCTAssertEqual(reopened.readingBatch?.next?.path,second.path)
        reopened.resumeReadingBatch()
        XCTAssertEqual(reopened.activeWorkspace?.displayPath,second.path)
    }

    func testReviewQueueAndSourceIndexRespectScopeAndKeepFullSource() throws {
        let pub = ReadingPublication053(periodical:"萬國公報",issue:"卷三 · 第十期",published:"1907")
        let a = ReadingCitation(source:SourceRef(path:"/tmp/one.pdf",fileName:"one.pdf",page:2,pageLabel:"十五"),title:"報刊",publication:pub)
        let b = ReadingCitation(source:SourceRef(path:"/tmp/two.pdf",fileName:"two.pdf",page:0),title:"別冊")
        let one = ReadingRecord(kind:.excerpt,quote:"原文 *",citations:[a])
        let two = ReadingRecord(kind:.image,quote:"已查",citations:[a],extras:ReadingRecordExtras053(review:.verified))
        let outside = ReadingRecord(kind:.excerpt,quote:"另外",citations:[b])
        let state = ReadingJournalState(records:[one,two,outside])
        XCTAssertEqual(ReadingExcerptReviewQueue.records(state,paths:[ReadingBookIdentity.key(a.source.path)]).map(\.id),[one.id])
        let text = ReadingNoteCitationInsertion.markdown(one)
        XCTAssertTrue(text.contains("> 原文 \\*"))
        XCTAssertTrue(text.contains("印刷页码 十五"))
        var options = ReadingExportOptions()
        options.includeSourceIndex = true
        let snapshot = ReadingExportSnapshot(title:"史料",records:[one,two,outside],options:options)
        let index = ReadingSourceIndex(snapshot)
        XCTAssertEqual(index.entries.count,2)
        let markdown = ReadingRecordExport.markdown(snapshot,imageFolder:"images")
        XCTAssertTrue(markdown.contains("## 出处索引"))
        XCTAssertTrue(markdown.contains("卷三 · 第十期"))
        XCTAssertTrue(markdown.contains("kongfolio://source"))
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let rich = try ReadingRecordExport.rich(snapshot,assets:root)
        let pdf = try rich.pdf()
        let pages = (0..<pdf.pageCount).compactMap{pdf.page(at:$0)}
        XCTAssertTrue(pages.contains{$0.string?.contains("出处索引") == true})
        XCTAssertTrue(pages.flatMap(\.annotations).contains{$0.url?.scheme == "kongfolio"})
        let word = root.appendingPathComponent("导出.docx")
        try ReadingRecordExport.word(snapshot,assets:root,to:word)
        let entries = try ReadingExportAudit.storedZIP(Data(contentsOf:word))
        let xml = try XCTUnwrap(entries["word/document.xml"])
        XCTAssertTrue(String(decoding:xml,as:UTF8.self).contains("出处索引"))
    }

    @MainActor func testExportRepairChangesOnlySelectedCitationAndKeepsOrder() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let one = ReadingRecord(kind:.excerpt,quote:"甲")
        let two = ReadingRecord(kind:.excerpt,quote:"乙")
        journal.add(one)
        journal.add(two)
        let snapshot = ReadingExportSnapshot(title:"导出",records:[one],order:["r:"+one.id.uuidString])
        let issues = try await ReadingOutputReview.shared.inspect(snapshot,assets:root)
        let target = try XCTUnwrap(issues.first?.source)
        let source = ReadingCitation(source:SourceRef(path:"/tmp/one.pdf",fileName:"one.pdf",page:1),title:"校订")
        try target.apply(source,replacing:nil,in:journal)
        let refreshed = snapshot.refreshed(in:journal)
        XCTAssertEqual(refreshed.orderedItems.map(\.id),snapshot.orderedItems.map(\.id))
        XCTAssertEqual(refreshed.records.first?.citations,[source])
        XCTAssertEqual(journal.record(two.id)?.citations,[])
        XCTAssertThrowsError(try target.apply(source,replacing:nil,in:journal))
    }
}
