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

    func testIssueNavigationUsesPreferredEditionAndOnlyReportsComparableGaps() throws {
        let first = LibraryBook(path:"/萬國公報_1907_9.pdf",title:"原刊")
        let duplicate = LibraryBook(path:"/OCR.pdf",title:"扫描后 OCR",shelfPeriodical:"万国公报",shelfYear:"1907年",
                                    shelfIssue:"第九期",shelfEdition:.ocr,shelfPreferredEdition:true)
        let next = LibraryBook(path:"/万国公报_1907_12.pdf",title:"下一期")
        let newYear = LibraryBook(path:"/万国公报_1908_19.pdf",title:"次年")
        let books = [next,first,newYear,duplicate]
        let index = ShelfPeriodicalIndex(books,publication:"万国公报")
        XCTAssertEqual(index.groups.map{$0.issues.count},[2,1])
        XCTAssertEqual(index.issues.first?.preferred.id,duplicate.id)
        XCTAssertEqual(index.neighbors(of:duplicate).next?.preferred.id,next.id)
        XCTAssertEqual(index.neighbors(of:next).previous?.preferred.id,duplicate.id)
        let current = try XCTUnwrap(ReaderShelfIssue(books:books,path:first.path))
        let following = try XCTUnwrap(current.next)
        XCTAssertEqual(current.key.missingIssues(toward:following.id),"书架缺少第 10–11 期")
        XCTAssertNil(following.id.missingIssues(toward:try XCTUnwrap(index.issues.last).id))
    }

    func testImportFlagsIssuesAndChecklistKeepsExactSource() throws {
        let original = LibraryBook(path:"/萬國公報_1907_12.pdf",title:"原刊 | \"摘录\"",shelfEdition:.original)
        let alternate = ShelfImportDraft(URL(fileURLWithPath:"/another/万国公报_1907_12.pdf"))
        var conflict = ShelfImportDraft(URL(fileURLWithPath:"/万国公报_1907_20.pdf"))
        conflict.periodical = "试刊"
        conflict.year = ""
        let drafts = [alternate,conflict]
        let warnings = ShelfImportAudit.warnings(drafts,chosen:Set(drafts.map(\.id)),existing:[original])
        XCTAssertEqual(warnings[alternate.id],["同一期已有其他文件"])
        XCTAssertEqual(warnings[conflict.id],["缺少年份","与文件名不一致：刊名"])
        let key = ReadingBookIdentity.key(original.path)
        let summaries = [key:ShelfRecordSummary(counts:["摘录":2])]
        let csv = ShelfChecklist.render(.csv,books:[original],progress:[:],summaries:summaries)
        let markdown = ShelfChecklist.render(.md,books:[original],progress:[:],summaries:summaries)
        XCTAssertTrue(csv.contains("原刊 | \"\"摘录\"\""))
        XCTAssertTrue(markdown.contains("原刊 \\|"))
        XCTAssertTrue(markdown.contains(" | 2 | [打开原文]"))
        let address = try XCTUnwrap(markdown.components(separatedBy:"(<").last?.components(separatedBy:">)").first)
        let link = try XCTUnwrap(URL(string:address))
        XCTAssertEqual(try ReadingShortcut.read(link).path,original.path)
    }

    func testShelfShortcutsUseMostRecentlyEditedNoteAndVerifiedExcerpt() throws {
        let source = SourceRef(path:"/tmp/original.pdf",fileName:"original.pdf",page:1,pageLabel:"十五")
        let citation = ReadingCitation(source:source,title:"原刊")
        let earlier = Date(timeIntervalSince1970:10), later = Date(timeIntervalSince1970:20)
        let note = ReadingRecord(kind:.note,note:"继续写这条",citations:[citation],created:earlier,modified:later)
        let newestCreated = ReadingRecord(kind:.note,note:"新建但更早修改",citations:[citation],created:later,modified:earlier)
        let reviewed = ReadingRecord(kind:.excerpt,quote:"已核对",citations:[citation],modified:earlier,
                                     extras:ReadingRecordExtras053(review:.verified))
        let unreviewed = ReadingRecord(kind:.excerpt,quote:"还未核对",citations:[citation],modified:later)
        var state = ReadingJournalState()
        state.records = [note,newestCreated,reviewed,unreviewed]
        let summary = try XCTUnwrap(ShelfRecordSummary.index(state)[ReadingBookIdentity.key(source.path)])
        XCTAssertEqual(summary.latestNote?.id,.record(note.id))
        XCTAssertEqual(summary.latestVerifiedExcerpt?.id,.record(reviewed.id))
        XCTAssertEqual(summary.latestVerifiedExcerpt?.citations053.first?.source,source)
    }

    @MainActor func testFailedQueueLoadPreservesPreviousDocumentAndDeferralPersists() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let first = try Release037Tests().pdf(root,name:"first.pdf")
        let missing = try Release037Tests().pdf(root,name:"missing.pdf")
        let last = try Release037Tests().pdf(root,name:"last.pdf")
        for file in [first,missing,last] {
            var bytes = try Data(contentsOf:file)
            bytes.append(contentsOf:("\n% "+file.lastPathComponent+"\n").utf8)
            try bytes.write(to:file)
        }
        let store = WorkspaceStore(storage:root,readingDefaults:Release037Tests().suite())
        store.bootstrap()
        store.maxLoadedTabs = 1
        try store.library.add([first,missing,last])
        let books = store.library.books
        XCTAssertEqual(books.count,3)
        guard books.count == 3 else { return }
        try store.library.enqueueShelfBooks(books.map(\.id))
        try await store.openShelfQueueBook(books[0])
        let selected = store.activeWorkspace?.id
        let tabCount = store.tabs.count
        try Data("invalid PDF".utf8).write(to:URL(fileURLWithPath:books[1].path))
        do {
            try await store.openShelfQueueBook(books[1])
            XCTAssertTrue(false,"A damaged PDF must not replace the current document")
        } catch {
            XCTAssertEqual(store.activeWorkspace?.id,selected)
            XCTAssertEqual(store.tabs.count,tabCount)
            XCTAssertEqual(store.library.catalog.queueCursor,books[0].id)
        }
        try store.library.setShelfQueueDeferred(books[1].id,true)
        let reopened = BookLibrary(storage:root)
        XCTAssertTrue(reopened.isShelfQueueDeferred(books[1].id))
        XCTAssertEqual(reopened.resumeShelfQueueBook()?.id,books[0].id)
        XCTAssertEqual(reopened.nextShelfQueueBook()?.id,books[2].id)
        try await store.openShelfQueueBook(books[2])
        XCTAssertFalse(store.tabs.contains(where:{$0.id == selected}))
        XCTAssertEqual(BookLibrary(storage:root).resumeShelfQueueBook()?.id,books[2].id)
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
