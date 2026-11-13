import XCTest
@testable import KongFolio

final class ReadingWorkflowPolishTests: XCTestCase {
    @MainActor func testBatchHistoryMigratesAndKeepsEarlierProgress() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let defaults = Release037Tests().suite()
        let legacy = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/earlier.pdf","status":"待读"}],"current":"00000000-0000-0000-0000-000000000001"}"#.utf8)
        defaults.set(legacy,forKey:ReadingOpenBatch.key)
        let store = WorkspaceStore(storage:root,readingDefaults:defaults)
        let old = try XCTUnwrap(store.readingBatch)
        let entry = try XCTUnwrap(old.next)
        store.startReadingBatch([URL(fileURLWithPath:"/tmp/earlier.pdf"),URL(fileURLWithPath:"/tmp/another.pdf")])
        store.updateBatchEntry(entry.id) { $0.status = .finished; $0.position = ViewPosition(selection:7) }
        XCTAssertEqual(store.readingBatch?.entry(entry.path)?.status,.pending)
        XCTAssertEqual(store.readingBatchPosition(entry.path)?.selection,7)
        let reopened = WorkspaceStore(storage:root,readingDefaults:defaults)
        XCTAssertEqual(reopened.readingBatches.count,2)
        reopened.selectedReadingBatchID = old.id
        XCTAssertEqual(reopened.readingBatch?.entry(entry.path)?.status,.finished)
        for i in 0..<ReadingOpenBatch.historyLimit {
            reopened.startReadingBatch([URL(fileURLWithPath:"/tmp/first-\(i).pdf"),URL(fileURLWithPath:"/tmp/second-\(i).pdf")])
        }
        XCTAssertEqual(ReadingOpenBatch.loadHistory(defaults).count,ReadingOpenBatch.historyLimit)
    }

    @MainActor func testDeferredExcerptSurvivesJournalReload() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let record = ReadingRecord(kind:.excerpt,quote:"待查的引文",citations:[
            ReadingCitation(source:SourceRef(path:"/tmp/source.pdf",fileName:"source.pdf",page:0),title:"原书")
        ])
        let journal = ReadingJournal(storage:root)
        journal.add(record)
        journal.updateExtras053([.record(record.id)]) { $0.reviewDeferred = true }
        try await journal.flush()
        let reopened = ReadingJournal(storage:root)
        XCTAssertEqual(reopened.record(record.id)?.extras?.reviewDeferred,true)
        XCTAssertNil(reopened.record(record.id)?.extras?.review)
        reopened.updateExtras053([.record(record.id)]) { $0.reviewDeferred = nil }
        try await reopened.flush()
        XCTAssertNil(ReadingJournal(storage:root).record(record.id)?.extras?.reviewDeferred)
    }

    func testExportReviewIdentifiesMissingPageAndLinkSeparately() async throws {
        let independent = ReadingRecord(kind:.note,note:"独立笔记")
        let excerpt = ReadingRecord(kind:.excerpt,quote:"引文",citations:[
            ReadingCitation(source:SourceRef(path:"",fileName:"",page:-1),title:"原书")
        ])
        var snapshot = ReadingExportSnapshot(title:"导出",records:[independent,excerpt])
        let root = URL(fileURLWithPath:"/tmp")
        let issues = try await ReadingOutputReview.shared.inspect(snapshot,assets:root)
        XCTAssertTrue(issues.contains { $0.message.contains("PDF 页码") })
        XCTAssertTrue(issues.contains { $0.message.contains("缺少原文链接") })
        XCTAssertTrue(issues.allSatisfy { $0.source?.item == .record(excerpt.id) })
        var options = ReadingExportOptions()
        options.includeSources = false
        snapshot.options = options
        let hidden = try await ReadingOutputReview.shared.inspect(snapshot,assets:root)
        XCTAssertTrue(hidden.isEmpty)
    }
}
