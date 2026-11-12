import XCTest
import PDFKit
@testable import KongFolio

final class ShelfCatalogToolsTests: XCTestCase {
    func testIssueInferenceOrderingAndTraditionalSearch() throws {
        let a = LibraryBook(path:"/萬國公報_1907_9.pdf",title:"萬國公報")
        let b = LibraryBook(path:"/万国公报_1907_10.pdf",title:"万国公报")
        let c = LibraryBook(path:"/萬國公報 第三卷 第二百一十六期.pdf",title:"萬國公報")
        XCTAssertEqual(a.issueMetadata.periodical,"萬國公報")
        XCTAssertEqual(a.issueMetadata.year,"1907")
        XCTAssertEqual(a.issueMetadata.issue,"9")
        XCTAssertEqual(ShelfText.issueOrder([b,a]).map(\.id),[a.id,b.id])
        XCTAssertEqual(c.matchingShelfField("万国公报"),"书名")
        XCTAssertEqual(c.matchingShelfField("第２１６期"),"期次")
        XCTAssertEqual(c.matchingShelfField("第二百一十六期"),"期次")
        XCTAssertNil(c.matchingShelfField("第16期"))
        XCTAssertEqual(c.matchingShelfField("第三卷"),"卷册")
    }

    @MainActor func testImportPreviewMetadataAndSavedFiltersPersist() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try Release037Tests().pdf(root,name:"万国公报_1907_216.pdf")
        var draft = ShelfImportDraft(file)
        draft.title = "报刊摘读"
        draft.topic = "近代史"
        let library = BookLibrary(storage:root)
        try await library.addInBackground([file],drafts:[draft])
        let book = try XCTUnwrap(library.books.first)
        XCTAssertEqual(book.title,"报刊摘读")
        XCTAssertEqual(book.shelfIssue,"216")
        XCTAssertTrue(book.shelfTopics.contains("近代史"))
        let filter = ShelfSavedFilter(title:"待读的报刊",scope:"topic:近代史",query:"万国公报",year:"1907",
                                      periodical:"万国公报",status:.unread,withExcerpts:false)
        try library.saveShelfFilter(filter)
        XCTAssertEqual(BookLibrary(storage:root).shelfFilters,[filter])
    }

    @MainActor func testDeleteAllReadingHistoryPreservesBookAndPosition() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let defaults = Release037Tests().suite()
        let file = try Release037Tests().pdf(root)
        let library = BookLibrary(storage:root)
        try library.add([file])
        let progress = ReadingProgress(visited:[0,2],last:2,date:Date(),pages:4,x:20,y:60)
        progress.save(path:file.path,defaults:defaults)
        for i in 0..<25 {
            ReadingProgress(last:1,date:Date(),pages:3).save(path:"/test-history-\(i).pdf",defaults:defaults)
        }
        let paths = Set(ReadingProgress.history(defaults:defaults).map(\.path))
        XCTAssertEqual(paths.count,26)
        ReadingProgress.setHistoryRemoved(paths,removed:true,defaults:defaults)
        XCTAssertTrue(ReadingProgress.history(defaults:defaults).isEmpty)
        XCTAssertEqual(ReadingProgress.load(path:file.path,defaults:defaults),progress)
        let shelf = try await library.refreshHistory(defaults:defaults)
        XCTAssertEqual(shelf[library.books[0].path],progress)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        ReadingProgress.setHistoryRemoved(paths,removed:false,defaults:defaults)
        XCTAssertEqual(ReadingProgress.history(defaults:defaults).count,26)
    }

    func testRecordOverviewCountsEachItemOnceAndShowsThreeNewest() throws {
        let path = "/tmp/书.pdf"
        let citation = ReadingCitation(source:SourceRef(path:path,fileName:"书.pdf",page:0),title:"书")
        var state = ReadingJournalState()
        state.records = [
            ReadingRecord(kind:.excerpt,quote:"摘录",citations:[citation,citation],created:Date(timeIntervalSince1970:1)),
            ReadingRecord(kind:.image,quote:"图",citations:[citation],created:Date(timeIntervalSince1970:2)),
            ReadingRecord(kind:.note,note:"笔记",citations:[citation],created:Date(timeIntervalSince1970:3)),
            ReadingRecord(kind:.comment,note:"评论",citations:[citation],created:Date(timeIntervalSince1970:4))
        ]
        let summary = try XCTUnwrap(ShelfRecordSummary.index(state)[ReadingBookIdentity.key(path)])
        XCTAssertEqual(summary.counts["摘录"],2)
        XCTAssertEqual(summary.counts["笔记"],1)
        XCTAssertEqual(summary.counts["PDF 评论"],1)
        XCTAssertEqual(summary.recent.map(\.kind),["PDF 评论","笔记","图片摘录"])
    }

    func testVersionReviewDistinguishesDifferentIssues() {
        let a = LibraryBook(path:"/万国公报_1907_216.pdf",title:"甲",shelfDigest:"one")
        let b = LibraryBook(path:"/萬國公報_1907_216.pdf",title:"乙",shelfDigest:"two")
        let c = LibraryBook(path:"/万国公报_1907_217.pdf",title:"甲",shelfDigest:"three")
        let versions = ShelfText.versions([a,b,c])
        XCTAssertEqual(versions[a.id]?.map(\.id),[b.id])
        XCTAssertNil(versions[c.id])
    }

    @MainActor func testTwentyBookQueuePersistsOrderAndReplacesItsPreviousTab() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root,readingDefaults:Release037Tests().suite())
        store.bootstrap()
        var files: [URL] = []
        let original = try Data(contentsOf:Release037Tests().pdf(root))
        for index in 1...20 {
            let url = root.appendingPathComponent("测试_1907_\(index).pdf")
            var data = original
            data.append(contentsOf:"\n% queue sample \(index)\n".utf8)
            try data.write(to:url)
            files.append(url)
        }
        try await store.library.addInBackground(files)
        let books = store.library.books
        try store.library.enqueueShelfBooks(books.map(\.id))
        try store.library.moveShelfQueue(books[1].id,before:books[0].id)
        let reopened = BookLibrary(storage:root)
        XCTAssertEqual(reopened.readingQueue.count,20)
        XCTAssertEqual(reopened.readingQueue.first?.id,books[1].id)
        try await store.openShelfQueueBook(books[1])
        let first = try XCTUnwrap(store.activeWorkspace)
        XCTAssertEqual(store.library.nextShelfQueueBook()?.id,books[0].id)
        try await store.openShelfQueueBook(books[0])
        XCTAssertFalse(store.tabs.contains(where:{$0.id == first.id}))
        XCTAssertEqual(store.tabs.compactMap(\.workspace).filter{$0.count > 0}.count,1)
        XCTAssertEqual(BookLibrary(storage:root).catalog.queueCursor,books[0].id)
    }
}
