import XCTest
import PDFKit
import SQLite3
@testable import KongFolio

final class Release027Tests: XCTestCase {
    func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("kf027-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func pdf(_ texts:[String]) throws -> Data {
        let source=DocumentServicesTests().fixture(),output=PDFDocument()
        for (index,text) in texts.enumerated() {
            let lines=text.components(separatedBy:"\n").enumerated().map { offset,value in RecognizedLine(text:value,box:CGRect(x:0.1,y:0.8-Double(offset)*0.1,width:0.8,height:0.05)) }
            output.insert(try DocumentServices.searchablePage(source.page(at:index%3)!,lines:lines),at:output.pageCount)
        }
        return output.dataRepresentation()!
    }
    func run(_ folder:URL,query:String="history",recursive:Bool=true,index:URL?=nil,limit:Int=1000) throws -> FolderSearchSummary {
        try FolderSearchService.run(folder:folder,query:query,recursive:recursive,indexURL:index ?? folder.appendingPathComponent("cache/index.sqlite"),limit:limit)
    }
    func modifySQL(_ url:URL,_ sql:String) throws {
        var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
    }
    @MainActor func wait(_ model:FolderSearchModel) async throws {
        let until=Date().addingTimeInterval(15)
        while model.running && Date()<until { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertFalse(model.running)
    }
    func testEnumerationIncludesSubfoldersAndSkipsHiddenPackagesAndSymlinks() throws {
        let root=try folder(),outside=try folder();defer { try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside) }
        for sub in ["sub",".hidden","skip.app"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(sub),withIntermediateDirectories:true) }
        let data=try pdf(["history"])
        for path in ["same.pdf","sub/same.PDF",".secret.pdf",".hidden/file.pdf","skip.app/file.pdf"] { try data.write(to:root.appendingPathComponent(path)) }
        try data.write(to:outside.appendingPathComponent("outside.pdf"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("linked.pdf"),withDestinationURL:outside.appendingPathComponent("outside.pdf"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("linked-folder"),withDestinationURL:outside)
        let all=try FolderSearchService.enumerate(root,recursive:true)
        XCTAssertEqual(all.files.map { FolderSearchService.relativePath($0,in:root) },["same.pdf","sub/same.PDF"])
        XCTAssertEqual(try FolderSearchService.enumerate(root,recursive:false).files.count,1)
    }
    func testMatchingUsesSimplifiedTraditionalCaseAndChineseLineBreaks() {
        var cache:[String:String]=[:]
        let page=FolderSearchPage(index:3,text:"史料：繁體\n歷史資料；HISTORY",label:"iv")
        let chinese=FolderSearchService.matches(page,query:"繁体历史资料",limit:10,cache:&cache)
        XCTAssertEqual(chinese.count,1);XCTAssertEqual(chinese[0].page,3);XCTAssertEqual(chinese[0].label,"iv")
        XCTAssertTrue(chinese[0].range.length>0)
        XCTAssertEqual(FolderSearchService.matches(page,query:"history",limit:10,cache:&cache).count,1)
        XCTAssertTrue(FolderSearchService.matches(page,query:"history",limit:0,cache:&cache).isEmpty)
    }
    func testVerticalMatchingSpansColumnsAndPreservesBoxes() throws {
        var cache:[String:String]=[:]
        let glyphs=[OrderedText.Glyph(text:"歷",box:CGRect(x:0.7,y:0.6,width:0.1,height:0.1),column:0,approximate:false),OrderedText.Glyph(text:"史",box:CGRect(x:0.7,y:0.4,width:0.1,height:0.1),column:0,approximate:false),OrderedText.Glyph(text:"學",box:CGRect(x:0.4,y:0.7,width:0.1,height:0.1),column:1,approximate:false)]
        let page=FolderSearchPage(index:0,text:"歷史學",glyphs:glyphs)
        let stored=try JSONDecoder().decode(FolderSearchPage.self,from:JSONEncoder().encode(page))
        let hits=FolderSearchService.matches(stored,query:"历史学",limit:10,cache:&cache)
        XCTAssertEqual(hits.count,1);XCTAssertEqual(hits[0].strips?.count,2)
        XCTAssertEqual(hits[0].strips?[0],glyphs[0].box.union(glyphs[1].box))
    }
    func testSearchFindsMultipleFilesWithSameBasenameAndReusesIndexForNewQuery() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("sub"),withIntermediateDirectories:true)
        try pdf(["history one","history two"]).write(to:root.appendingPathComponent("book.pdf"))
        try pdf(["history three"]).write(to:root.appendingPathComponent("sub/book.pdf"))
        let first=try run(root)
        XCTAssertEqual(first.hits.count,3);XCTAssertEqual(first.totalFiles,2);XCTAssertTrue(first.files.allSatisfy { !$0.cached })
        XCTAssertEqual(Set(first.hits.map(\.relativePath)),["book.pdf","sub/book.pdf"])
        let second=try run(root,query:"three")
        XCTAssertEqual(second.hits.count,1);XCTAssertTrue(second.files.allSatisfy(\.cached))
        XCTAssertEqual(second.hits[0].relativePath,"sub/book.pdf")
    }
    func testFingerprintInvalidatesEvenWhenFileSizeAndModificationTimeStayTheSame() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf"),data=try pdf(["history"])
        try (data+Data("\n%first\n".utf8)).write(to:file)
        let date=(try FileManager.default.attributesOfItem(atPath:file.path))[.modificationDate] as! Date
        _=try run(root);XCTAssertTrue(try run(root).files[0].cached)
        try (data+Data("\n%other\n".utf8)).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file.path)
        let refreshed=try run(root)
        XCTAssertFalse(refreshed.files[0].cached);XCTAssertEqual(refreshed.hits.count,1)
        try pdf(["different words"]).write(to:file)
        XCTAssertTrue(try run(root).hits.isEmpty)
    }
    func testCorruptPageCacheIsRebuiltWithoutDuplicatingPartialMatches() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        try pdf(["history first","history second"]).write(to:root.appendingPathComponent("book.pdf"))
        _=try run(root)
        try modifySQL(root.appendingPathComponent("cache/index.sqlite"),"UPDATE pages SET digest='broken' WHERE position=1")
        let result=try run(root)
        XCTAssertEqual(result.hits.count,2);XCTAssertFalse(result.files[0].cached);XCTAssertNotNil(result.files[0].warning)
        XCTAssertTrue(try run(root).files[0].cached)
    }
    func testInterruptedIndexTransactionKeepsPreviousCompletedVersion() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let cache=try FolderSearchIndex(url:root.appendingPathComponent("index.sqlite"))
        let page=FolderSearchPage(index:0,text:"old")
        try cache.begin(path:"book",digest:"old",pages:1);try cache.write(page,path:"book");try cache.commit(path:"book",textPages:1)
        try cache.begin(path:"book",digest:"new",pages:2);try cache.write(FolderSearchPage(index:0,text:"new"),path:"book");cache.rollback()
        var texts:[String]=[]
        XCTAssertTrue(try cache.read(path:"book",digest:"old") { texts.append($0.text) })
        XCTAssertEqual(texts,["old"])
        XCTAssertFalse(try cache.read(path:"book",digest:"new") { _ in })
    }
    func testCancellationRollsBackPartiallyExtractedDocumentAndCanRestart() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf"),index=root.appendingPathComponent("cache/index.sqlite"),data=try pdf(Array(repeating:"history",count:20))
        try data.write(to:file)
        let worker=Task.detached {
            try FolderSearchService.run(folder:root,query:"history",recursive:true,indexURL:index) { event in
                if case .page(_,let page,_) = event,page==1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        var canceled=false
        do { _=try await worker.value } catch is CancellationError { canceled=true }
        XCTAssertTrue(canceled)
        let cache=try FolderSearchIndex(url:index)
        XCTAssertFalse(try cache.read(path:file.path,digest:OCRPageCache.digest(data)+"|"+ProcessInfo.processInfo.operatingSystemVersionString) { _ in })
        let restarted=try run(root)
        XCTAssertEqual(restarted.hits.count,20);XCTAssertFalse(restarted.files[0].cached)
    }
    func testResultLimitStopsFurtherFilesAndBoundsDensePageMatches() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        try pdf(["history history history"]).write(to:root.appendingPathComponent("a.pdf"))
        try pdf(["history"]).write(to:root.appendingPathComponent("b.pdf"))
        let result=try run(root,limit:2)
        XCTAssertEqual(result.hits.count,2);XCTAssertTrue(result.truncated);XCTAssertEqual(result.files.count,1);XCTAssertEqual(result.totalFiles,2)
        var folding:[String:String]=[:]
        XCTAssertEqual(ReadingServices.matches(in:String(repeating:"x",count:10000),query:"x",cache:&folding,limit:4).count,4)
    }
    func testUnavailableIndexStillReturnsSearchResults() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        try pdf(["history"]).write(to:root.appendingPathComponent("book.pdf"))
        let blocked=root.appendingPathComponent("not-directory");try Data([0]).write(to:blocked)
        let result=try run(root,index:blocked.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(result.hits.count,1);XCTAssertNotNil(result.indexWarning);XCTAssertNil(result.files[0].error)
    }
    func testReportsImageOnlyCorruptAndEncryptedFilesWithoutLosingGoodResults() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to:root.appendingPathComponent("scan.pdf"))
        try Data("bad pdf".utf8).write(to:root.appendingPathComponent("bad.pdf"))
        try pdf(["history"]).write(to:root.appendingPathComponent("good.pdf"))
        let encrypted=PDFDocument(data:try pdf(["history secret"]))!
        XCTAssertTrue(encrypted.write(to:root.appendingPathComponent("locked.pdf"),withOptions:[.ownerPasswordOption:"owner",.userPasswordOption:"secret"]))
        let result=try run(root)
        XCTAssertEqual(result.hits.count,1)
        XCTAssertEqual(result.files.filter(\.needsOCR).map { $0.url.lastPathComponent },["scan.pdf"])
        XCTAssertEqual(result.files.filter { $0.error != nil }.count,2)
    }
    func testEmptyFolderAndInvalidInputs() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertEqual(try run(root).totalFiles,0)
        XCTAssertThrowsError(try run(root,query:" \n "))
        XCTAssertThrowsError(try run(root,limit:0))
        XCTAssertThrowsError(try run(root.appendingPathComponent("missing")))
    }
    func testVerifiedResultHasCoordinatesAndRejectsModifiedOrDeletedOriginal() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf");try pdf(["first","history target"]).write(to:file)
        let hit=try run(root).hits[0],verified=try FolderSearchService.verify(hit)
        XCTAssertEqual(verified.source.page,1);XCTAssertFalse(verified.source.rects.isEmpty)
        try pdf(["history changed"]).write(to:file)
        XCTAssertThrowsError(try FolderSearchService.verify(hit))
        try FileManager.default.removeItem(at:file)
        XCTAssertThrowsError(try FolderSearchService.verify(hit))
    }
    @MainActor func testOpeningResultLoadsExactPageAndReusesExistingTab() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf");try pdf(["first","history target"]).write(to:file)
        let result=try run(root).hits[0],verified=try FolderSearchService.verify(result),store=WorkspaceStore(storage:root.appendingPathComponent("app"));store.bootstrap()
        try store.openFolderSearchResult(result,verified:verified)
        XCTAssertEqual(store.activeWorkspace?.selection,1);XCTAssertEqual(store.activeWorkspace?.sourceURL,file);XCTAssertEqual(store.tabs.count,1)
        try store.openFolderSearchResult(result,verified:verified)
        XCTAssertEqual(store.tabs.count,1);XCTAssertFalse(store.activeWorkspace!.dirty)
    }
    @MainActor func testOpeningPreservesUnsavedWorkAndDoesNotCreateAnotherTab() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf");try pdf(["history"]).write(to:file)
        let result=try run(root).hits[0],verified=try FolderSearchService.verify(result),store=WorkspaceStore(storage:root.appendingPathComponent("app"));store.bootstrap()
        try store.openFolderSearchResult(result,verified:verified)
        let current=store.activeWorkspace!;current.document.page(at:0)!.rotation=90;current.edited()
        XCTAssertThrowsError(try store.openFolderSearchResult(result,verified:verified))
        XCTAssertEqual(current.document.page(at:0)!.rotation,90);XCTAssertTrue(current.dirty);XCTAssertEqual(store.tabs.count,1)
    }
    @MainActor func testOpeningRejectsStaleAlreadyLoadedDocument() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf");try pdf(["history old"]).write(to:file)
        let store=WorkspaceStore(storage:root.appendingPathComponent("app"));store.bootstrap()
        let old=try run(root).hits[0];try store.openFolderSearchResult(old,verified:FolderSearchService.verify(old))
        let loaded=try store.activeWorkspace!.pdfData()
        try pdf(["history new"]).write(to:file)
        let fresh=try run(root).hits[0]
        XCTAssertThrowsError(try store.openFolderSearchResult(fresh,verified:FolderSearchService.verify(fresh)))
        XCTAssertEqual(try store.activeWorkspace!.pdfData(),loaded);XCTAssertEqual(store.tabs.count,1)
    }
    @MainActor func testResultLoadsAnExistingDeferredTabWithoutDuplicateImport() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf");try pdf(["first","history"]).write(to:file)
        let store=WorkspaceStore(storage:root.appendingPathComponent("app"));store.bootstrap()
        let deferred=store.addWorkspace();deferred.sourceURL=file;deferred.needsLoad=true
        let result=try run(root).hits[0]
        try store.openFolderSearchResult(result,verified:FolderSearchService.verify(result))
        XCTAssertEqual(store.activeWorkspace?.id,deferred.id);XCTAssertFalse(deferred.needsLoad);XCTAssertEqual(deferred.selection,1)
        XCTAssertEqual(store.tabs.count,2)
    }
    @MainActor func testModelRemembersSettingsExportsReportAndClearsOnlyItsIndex() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("book.pdf");let bytes=try pdf(["history target"]);try bytes.write(to:file)
        let app=root.appendingPathComponent("app"),model=FolderSearchModel(storage:app);model.folder=root;model.query="history";model.recursive=false
        model.start();try await wait(model)
        XCTAssertEqual(model.results.count,1);XCTAssertTrue(model.report().contains(file.path));XCTAssertTrue(model.report().contains("第 1 页"))
        let restored=FolderSearchModel(storage:app)
        XCTAssertEqual(restored.folder,root);XCTAssertEqual(restored.query,"history");XCTAssertFalse(restored.recursive)
        model.clearIndex();XCTAssertFalse(FileManager.default.fileExists(atPath:model.indexURL.path))
        XCTAssertEqual(model.results.count,1);XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    @MainActor func testModelCancellationAndNewQueryDoNotMixOldResults() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        try pdf(Array(repeating:"history",count:25)).write(to:root.appendingPathComponent("book.pdf"))
        let model=FolderSearchModel(storage:root.appendingPathComponent("app"));model.folder=root;model.query="history"
        model.start();model.cancel();try await wait(model)
        model.query="no such words";model.start();try await wait(model)
        XCTAssertTrue(model.results.isEmpty);XCTAssertEqual(model.searchedQuery,"no such words");XCTAssertEqual(model.scanned,1)
    }
}
