import XCTest
@testable import KongFolio

@MainActor final class HomeReadingTests: XCTestCase {
    func testLatestNoteUsesModifiedDateAndSkipsEmptyAndRemovedItems() {
        let before = Date(timeIntervalSince1970:10)
        let after = Date(timeIntervalSince1970:20)
        let note = ReadingRecord(kind:.note,note:"文献笔记",created:after,modified:before)
        let essay = ReadingEssay(title:"继续写的笔记",created:before,modified:after)
        let removed = ReadingRecord(kind:.note,note:"已删除",modified:.distantFuture,removed:after)
        var state = ReadingJournalState()
        state.records = [note,removed,ReadingRecord(kind:.note,modified:.distantFuture)]
        state.essays = [essay]
        XCTAssertEqual(ReadingLibraryItem.latestHomeNote(state)?.id,.essay(essay.id))
        state.essays[0].removed = after
        XCTAssertEqual(ReadingLibraryItem.latestHomeNote(state)?.id,.record(note.id))
        XCTAssertNil(ReadingLibraryItem.latestHomeNote(state)?.homeSource)
    }

    func testUntitledNoteUsesFirstNonemptyLineAndPreservesSource() {
        let citation = ReadingCitation(source:SourceRef(path:"/tmp/book.pdf",fileName:"book.pdf",page:6),title:"史料")
        let note = ReadingRecord(kind:.note,title:"未命名笔记",note:"  \n  第一行内容  \n第二行",citations:[citation])
        let item = ReadingLibraryItem.record(note)
        XCTAssertEqual(item.homeNoteTitle,"第一行内容")
        XCTAssertEqual(item.homeNotePreview,"第一行内容")
        XCTAssertEqual(item.homeSource?.1,citation)
    }

    func testFinishingBatchOpensOnlyFollowingPendingDocument() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let pdf = try Release046Tests().pdf(root,pages:2)
        let prior = root.appendingPathComponent("first.pdf")
        let next = root.appendingPathComponent("next.pdf")
        try FileManager.default.copyItem(at:pdf,to:prior)
        try FileManager.default.copyItem(at:pdf,to:next)
        store.startReadingBatch([prior,pdf,next])
        let batch = try XCTUnwrap(store.readingBatch)
        let current = batch.entries[1]
        workspace.load([pdf],prepared:.documents([try Data(contentsOf:pdf)]))
        workspace.readingBatchEntryID = current.id
        store.trackBatchSelection(workspace)
        XCTAssertEqual(store.readingBatch?.sharesHomeResume(with:pdf.path),true)
        XCTAssertEqual(store.readingBatch?.sharesHomeResume(with:prior.path),false)
        await store.finishReadingAndOpenNext(workspace)
        XCTAssertEqual(store.readingBatch?.entries[1].status,.finished)
        XCTAssertEqual(store.activeWorkspace?.displayPath,next.path)
        XCTAssertEqual(store.tabs.compactMap { $0.workspace?.displayPath }.sorted(),[pdf.path,next.path].sorted())
        store.activeWorkspace?.cancelImport()
    }

    func testCancelledCloudResumeDoesNotOpenOrOverwriteNewRequest() async throws {
        let job = HomeReadingPreparation()
        let path = "/tmp/test.pdf"
        let shortcut = ReadingShortcut(path:path,title:"文献",position:ViewPosition())
        var opened = 0
        job.start(shortcut,trackedPath:path,prepare:{ _,progress in
            progress("正在下载 iCloud 文件")
            try? await Task.sleep(nanoseconds:1_000_000_000)
            progress("旧任务的迟到消息")
        },resolve:{ URL(fileURLWithPath:$0.path) }) { _ in
            opened += 1
            return true
        }
        try await waitForPhase(job,.downloading("正在下载 iCloud 文件"))
        job.cancel()
        XCTAssertNil(job.phase)
        job.start(shortcut,trackedPath:path,prepare:{ _,_ in },resolve:{ URL(fileURLWithPath:$0.path) }) { _ in
            opened += 1
            return false
        }
        try await waitForPhase(job,.ready)
        XCTAssertEqual(opened,1)
        XCTAssertEqual(job.phase,.ready)
    }

    func testMissingFileStaysOnHomeWithRelinkState() async throws {
        let job = HomeReadingPreparation()
        let path = "/tmp/"+UUID().uuidString+".pdf"
        job.start(ReadingShortcut(path:path,title:"文献",position:ViewPosition()),trackedPath:path) { _ in
            XCTFail("Missing file cannot open")
            return true
        }
        try await waitForPhase(job,.missing)
        XCTAssertEqual(job.path,path)
    }

    private func waitForPhase(_ preparation: HomeReadingPreparation,_ phase: HomeReadingPreparation.Phase) async throws {
        let deadline = Date().addingTimeInterval(3)
        while preparation.phase != phase && Date() < deadline {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTAssertEqual(preparation.phase,phase)
    }

    func testSearchPreservesScopeMatchAndRecordAcrossStores() throws {
        let name = "KongFolio.HomeTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let match = HomeReadingSearch.PDFMatch(page:8,range:NSRange(location:10,length:3),strips:nil,index:2)
        let pdf = HomeReadingSearch(scope:.pdf,query:"袁世凯",path:"/tmp/book.pdf",pdfMatch:match)
        pdf.save(defaults)
        XCTAssertEqual(HomeReadingSearch.load(try XCTUnwrap(UserDefaults(suiteName:name))),pdf)
        let record = ReadingLibraryID.record(UUID())
        let scope = HomeReadingSearch.DeskFilter(source:.book("/tmp/book.pdf"),tag:"专题",recent:true,removed:false)
        let notes = HomeReadingSearch(scope:.notes,query:"教会",path:"/tmp/book.pdf",record:record,deskFilter:scope)
        notes.save(defaults)
        HomeReadingSearch(scope:.library,query:" ").save(defaults)
        XCTAssertEqual(HomeReadingSearch.load(defaults),notes)
    }

    func testPinnedFoldersOnlyComeFromExplicitSettings() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.readingDefaults.set(["/tmp/unrelated"],forKey:"NSRecentDocuments")
        XCTAssertTrue(store.homePinnedFolders.isEmpty)
        let folder = HomePinnedFolder(path:root.path)
        store.updateHomeFolders([folder])
        XCTAssertEqual(HomePinnedFolder.load(store.readingDefaults),[folder])
        store.updateHomeFolders([])
        XCTAssertEqual(HomePinnedFolder.load(store.readingDefaults),[])
    }

    func testLatestUnfinishedBatchOpensOnlyOneDocument() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let pdf = try Release046Tests().pdf(root,pages:2)
        let second = root.appendingPathComponent("second.pdf")
        try FileManager.default.copyItem(at:pdf,to:second)
        store.startReadingBatch([pdf,second])
        let batch = try XCTUnwrap(store.unfinishedHomeBatch)
        store.updateBatchEntry(batch.entries[0].id) { $0.status = .finished }
        let next = try XCTUnwrap(store.unfinishedHomeBatch?.next)
        XCTAssertEqual(next.id,batch.entries[1].id)
        store.openReadingBatchEntry(next)
        XCTAssertEqual(store.tabs.compactMap { $0.workspace?.displayPath },[second.path])
        XCTAssertEqual(store.activeWorkspace?.readingBatchEntryID,next.id)
        store.activeWorkspace?.cancelImport()
    }

    func testResumePDFSearchReturnsToTheSelectedMatch() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let pdf = try PDFTextSnapshot053Tests().fixture(root)
        let data = try Data(contentsOf:pdf)
        workspace.load([pdf],prepared:.documents([data]))
        let hit = try XCTUnwrap(ReadingServices.search(data,query:"FindPage2Only").first)
        let match = HomeReadingSearch.PDFMatch(page:hit.page,range:hit.range,strips:hit.strips,index:0)
        HomeReadingSearch(scope:.pdf,query:"FindPage2Only",path:pdf.path,pdfMatch:match).save(store.readingDefaults)
        _ = store.addWorkspace()
        try await store.resumeHomeSearch(try XCTUnwrap(HomeReadingSearch.load(store.readingDefaults)))
        let deadline = Date().addingTimeInterval(5)
        while workspace.searchCursor == nil && Date() < deadline {
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertTrue(store.rightPDFSearchWorkspace === workspace)
        XCTAssertEqual(workspace.searchCursor,0)
        XCTAssertEqual(workspace.selection,hit.page)
    }

    func testContinueReadingUsesSavedPositionAndRetainsPrintedPage() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let pdf = try Release046Tests().pdf(root,pages:3)
        let progress = ReadingProgress(last:2,date:Date(),pages:3,title:"文献",pageLabel:"壹")
        progress.save(path:pdf.path,defaults:store.readingDefaults)
        let item = try XCTUnwrap(ReadingProgress.history(defaults:store.readingDefaults).first)
        XCTAssertEqual(item.progress.pageLabel,"壹")
        try store.continueHomeReading(item,resolvedFile:pdf)
        XCTAssertEqual(workspace.pendingView?.selection,2)
        workspace.cancelImport()
    }
}
