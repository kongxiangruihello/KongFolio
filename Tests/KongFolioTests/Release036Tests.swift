import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release036Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func defaults() -> UserDefaults { UserDefaults(suiteName: "KongFolio.Reading036Tests." + UUID().uuidString)! }
    func book(_ root: URL, name: String = "一本书 & 阅读 #1.pdf") throws -> URL {
        let file = root.appendingPathComponent(name)
        try Release027Tests().pdf(["page one","page two","page three","page four"]).write(to: file)
        return file
    }
    @MainActor func workspace(_ root: URL, file: URL, suite: UserDefaults) throws -> Workspace {
        let w = Workspace(storage: root, readingDefaults: suite); w.bootstrap()
        let bytes = try Data(contentsOf: file); w.document = PDFDocument(data: bytes)!; w.cachedPDF = bytes; w.sourceURL = file
        return w
    }
    @MainActor func wait(_ w: Workspace) async throws {
        let deadline = Date().addingTimeInterval(10)
        while w.busy, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertFalse(w.busy); XCTAssertTrue(w.count > 0)
    }
    func testLegacyProgressRemainsReadableForKongSeek() {
        let suite = defaults(), path = "/books/旧书.pdf"
        suite.set(["last":2,"visited":"0-2","pages":8,"date":1_800_000_000.0],forKey:"KongFolio.progress."+path)
        let p=ReadingProgress.load(path:path,defaults:suite)
        XCTAssertEqual(p.last,2);XCTAssertEqual(p.visited,[0,1,2]);XCTAssertEqual(p.pages,8)
        XCTAssertEqual(p.resumePosition(pageCount:8)?.selection,2);XCTAssertNil(p.resumePosition(pageCount:2))
    }
    func testPositionScaleLayoutAndBookmarkRoundTrip() {
        let suite=defaults(), p=ReadingProgress(visited:[0,3],last:3,date:Date(timeIntervalSince1970:100),pages:5,x:28,y:420,scale:1.75,layout:.single,title:"书名",bookmark:Data([1,2,3]))
        p.save(path:"/book.pdf",defaults:suite)
        XCTAssertEqual(ReadingProgress.load(path:"/book.pdf",defaults:suite),p)
        XCTAssertEqual(p.resumePosition(pageCount:5),ViewPosition(selection:3,x:28,y:420,scale:1.75))
    }
    func testFirstPagePositionIsRememberedWithoutCountingVisit() {
        let p=ReadingProgress(last:0,date:Date(),pages:3,x:18,y:270,scale:2)
        XCTAssertEqual(p.resumePosition(pageCount:3)?.y,270);XCTAssertTrue(p.visited.isEmpty)
    }
    func testMalformedStoredCoordinatesAndScaleAreDiscarded() {
        let suite=defaults();suite.set(["last":1,"date":10.0,"x":Double.infinity,"y":12.0,"scale":-1.0],forKey:"KongFolio.progress./bad.pdf")
        let p=ReadingProgress.load(path:"/bad.pdf",defaults:suite)
        XCTAssertNil(p.x);XCTAssertNil(p.scale);XCTAssertNil(p.resumePosition(pageCount:1))
    }
    func testHistoryContainsClosedBooksAndSortsByReadingTime() {
        let suite=defaults()
        ReadingProgress(last:2,date:Date(timeIntervalSince1970:100),pages:4,title:"较早").save(path:"/old.pdf",defaults:suite)
        ReadingProgress(last:0,date:Date(timeIntervalSince1970:200),pages:6,title:"最新").save(path:"/new.pdf",defaults:suite)
        suite.set("ignored",forKey:"Other.Progress./book")
        XCTAssertEqual(ReadingProgress.history(defaults:suite).map(\.path),["/new.pdf","/old.pdf"])
        XCTAssertEqual(ReadingProgress.history(defaults:suite).first?.title,"最新")
    }
    @MainActor func testQuickPageChangeAndCloseKeepLocationBeforeVisitDelay() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),w=try workspace(root,file:file,suite:suite)
        w.selectPage(2);XCTAssertTrue(w.closeDocument())
        let saved=ReadingProgress.load(path:file.path,defaults:suite)
        XCTAssertEqual(saved.last,2);XCTAssertEqual(saved.pages,4);XCTAssertTrue(saved.visited.isEmpty);XCTAssertNotNil(saved.date)
    }
    @MainActor func testQuittingKeepsScrollZoomAndLayoutWithoutPDFEdits() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),before=try Data(contentsOf:file),suite=defaults(),w=try workspace(root,file:file,suite:suite)
        w.selection=1;w.readingPoint=CGPoint(x:12,y:345);w.readingScale=1.6;w.readingLayout = .twoUp
        XCTAssertTrue(w.prepareToClose())
        let saved=ReadingProgress.load(path:file.path,defaults:suite)
        XCTAssertEqual(saved.resumePosition(pageCount:4),ViewPosition(selection:1,x:12,y:345,scale:1.6));XCTAssertEqual(saved.layout,.twoUp);XCTAssertEqual(try Data(contentsOf:file),before)
    }
    @MainActor func testTabSwitchSavesOutgoingBookIndependently() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let suite=defaults(),file=try book(root),other=try book(root,name:"第二本.pdf"),store=WorkspaceStore(storage:root,readingDefaults:suite)
        let first=store.addWorkspace();first.document=PDFDocument(url:file)!;first.sourceURL=file;first.selection=2;first.readingPoint=CGPoint(x:5,y:88)
        let second=store.addWorkspace();second.document=PDFDocument(url:other)!;second.sourceURL=other;second.selection=1
        store.select(first.id)
        XCTAssertEqual(ReadingProgress.load(path:file.path,defaults:suite).last,2);XCTAssertEqual(ReadingProgress.load(path:other.path,defaults:suite).last,1)
    }
    @MainActor func testResumeUsesFullPositionAndExplicitNavigationWins() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),w=try workspace(root,file:file,suite:suite)
        ReadingProgress(last:2,date:Date(),pages:4,x:30,y:210,scale:1.4,layout:.single).save(path:file.path,defaults:suite)
        w.prepareReadingResume(path:file.path,enabled:true)
        XCTAssertEqual(w.pendingView?.selection,2);XCTAssertEqual(w.pendingView?.scale,1.4);XCTAssertEqual(w.pendingReadingLayout,.single)
        w.pendingView=ViewPosition(selection:1);w.prepareReadingResume(path:file.path,enabled:true);XCTAssertEqual(w.pendingView?.selection,1)
    }
    @MainActor func testDisabledResumeDoesNotChangeOpeningPosition() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),w=try workspace(root,file:file,suite:suite)
        ReadingProgress(last:2,date:Date(),pages:4).save(path:file.path,defaults:suite)
        w.prepareReadingResume(path:file.path,enabled:false);XCTAssertNil(w.pendingView)
    }
    @MainActor func testVisitDelayDoesNotWriteToAReplacedDocument() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let first=try book(root),second=try book(root,name:"replacement.pdf"),suite=defaults(),w=try workspace(root,file:first,suite:suite)
        w.selection=1;w.noteVisit(1);w.sourceURL=second
        try await Task.sleep(nanoseconds:1_650_000_000)
        XCTAssertTrue(ReadingProgress.load(path:first.path,defaults:suite).visited.isEmpty);XCTAssertTrue(ReadingProgress.load(path:second.path,defaults:suite).visited.isEmpty)
    }
    func testReadingLinkRoundTripsUnicodeAndURLCharactersWithoutBookmark() throws {
        let a=ReadingShortcut(path:"/中文 空格/书 &?#%.pdf",title:"书名",position:ViewPosition(selection:2,x:10,y:250,scale:1.2),bookmark:Data([1,2,3]))
        let b=try ReadingShortcut.read(a.link())
        XCTAssertEqual(b.path,a.path);XCTAssertEqual(b.position,a.position);XCTAssertNil(b.bookmark);XCTAssertTrue(ReadingShortcut.handles(try a.link()))
    }
    func testShortcutFileRoundTripAndOverwritePreserveOriginal() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),original=try Data(contentsOf:file),target=root.appendingPathComponent("书籍.kongfoliolink")
        var a=ReadingShortcut(path:file.path,title:"我的书",position:ViewPosition(selection:1));try a.write(to:target);XCTAssertEqual(try ReadingShortcut.read(target),a)
        a.mode = .fixed;a.position.selection=2;try a.write(to:target);XCTAssertEqual(try ReadingShortcut.read(target).position.selection,2);XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testInvalidOrRecursiveShortcutsAreRejected() throws {
        var a=ReadingShortcut(path:"relative.pdf",title:"bad",position:ViewPosition(selection:0));XCTAssertThrowsError(try a.validate())
        a.path="/book.pdf";a.version=99;XCTAssertThrowsError(try a.validate());a.version=1;a.position.selection = -1;XCTAssertThrowsError(try a.validate())
        a.position.selection=1;a.position.scale = .infinity;XCTAssertThrowsError(try a.validate());a.position.scale=nil;a.path="/nested.kongfoliolink";XCTAssertThrowsError(try a.validate())
    }
    func testMalformedReadingURLsAreRejected() throws {
        XCTAssertThrowsError(try ReadingShortcut.read(URL(string:"kongfolio://reading?ref=not-base64")!))
        XCTAssertThrowsError(try ReadingShortcut.read(URL(string:"https://example.org/reading?ref=e30=")!))
        XCTAssertThrowsError(try ReadingShortcut.read(URL(string:"kongfolio://reading?ref="+String(repeating:"A",count:200001))!))
    }
    func testShortcutRejectsUnpairedCoordinatesAndZeroZoom() throws {
        var a=ReadingShortcut(path:"/book.pdf",title:"bad",position:ViewPosition(selection:0,x:3));XCTAssertThrowsError(try a.validate())
        a.position.x=nil;a.position.scale=0;XCTAssertThrowsError(try a.validate())
    }
    func testMissingOriginalIsReportedWithoutCreatingAnything() throws {
        let a=ReadingShortcut(path:"/does-not-exist-kongfolio036/book.pdf",title:"missing",position:ViewPosition(selection:0))
        XCTAssertThrowsError(try a.resolvedURL())
    }
    func testNativeBookmarkFindsRenamedBook() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),moved=root.appendingPathComponent("改名后的书.pdf")
        let bookmark=try file.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        let a=ReadingShortcut(path:file.path,title:"old",position:ViewPosition(selection:1),bookmark:bookmark)
        try FileManager.default.moveItem(at:file,to:moved);XCTAssertEqual(try a.resolvedURL().resolvingSymlinksInPath().path,moved.resolvingSymlinksInPath().path)
    }
    func testResumeShortcutFollowsLatestPositionAndFixedLinkDoesNot() {
        let latest=ReadingProgress(last:3,date:Date(),pages:4,x:15,y:120,scale:1.8)
        var a=ReadingShortcut(path:"/book.pdf",title:"book",position:ViewPosition(selection:1,x:8,y:70,scale:1.2))
        XCTAssertEqual(a.destination(progress:latest,pageCount:4).selection,3);XCTAssertEqual(a.destination(progress:latest,pageCount:4).scale,1.8)
        a.mode = .fixed;XCTAssertEqual(a.destination(progress:latest,pageCount:4),a.position)
    }
    func testShortcutFallsBackAndClampsWhenBookGetsShorter() {
        let a=ReadingShortcut(path:"/book.pdf",title:"book",position:ViewPosition(selection:9))
        XCTAssertEqual(a.destination(progress:ReadingProgress(),pageCount:3).selection,2)
        XCTAssertEqual(a.destination(progress:ReadingProgress(),pageCount:0).selection,0)
    }
    @MainActor func testExistingBookShortcutReusesTabAndKeepsUnsavedEdits() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),store=WorkspaceStore(storage:root,readingDefaults:suite),w=store.addWorkspace()
        w.document=PDFDocument(url:file)!;w.sourceURL=file;w.dirty=true
        let mark=PDFAnnotation(bounds:CGRect(x:10,y:10,width:30,height:20),forType:.square,withProperties:nil);w.document.page(at:0)!.addAnnotation(mark)
        let a=ReadingShortcut(path:file.path,title:"book",mode:.fixed,position:ViewPosition(selection:2,x:12,y:140,scale:1.5),layout:.single)
        let opened=try store.openReadingShortcut(a);XCTAssertEqual(opened.id,w.id);XCTAssertEqual(store.tabs.count,1);XCTAssertEqual(w.selection,2);XCTAssertEqual(w.readingScale,1.5);XCTAssertTrue(w.dirty);XCTAssertTrue(w.document.page(at:0)!.annotations.contains(mark))
    }
    @MainActor func testShortcutLoadsClosedBookAtNewerSavedLocation() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),store=WorkspaceStore(storage:root,readingDefaults:suite)
        ReadingProgress(last:3,date:Date(),pages:4,x:14,y:320,scale:1.3,layout:.single).save(path:file.path,defaults:suite)
        let a=ReadingShortcut(path:file.path,title:"book",position:ViewPosition(selection:0))
        let opened=try store.openReadingShortcut(a);try await wait(opened)
        XCTAssertEqual(opened.selection,3);XCTAssertEqual(opened.readingScale,1.3);XCTAssertEqual(opened.readingPoint,CGPoint(x:14,y:320));XCTAssertEqual(opened.readingLayout,.single)
    }
    @MainActor func testShortcutUpdatesHistoryPathAfterBookmarkRename() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),w=try workspace(root,file:file,suite:suite)
        w.selection=2;let shortcut=try w.makeReadingShortcut(mode:.resume),moved=root.appendingPathComponent("移动后的书.pdf");try FileManager.default.moveItem(at:file,to:moved)
        let store=WorkspaceStore(storage:root.appendingPathComponent("new"),readingDefaults:suite),opened=try store.openReadingShortcut(shortcut);try await wait(opened)
        XCTAssertEqual(opened.sourceURL?.resolvingSymlinksInPath().path,moved.resolvingSymlinksInPath().path);XCTAssertEqual(opened.selection,2);XCTAssertEqual(ReadingProgress.load(path:moved.path,defaults:suite).last,2)
    }
    @MainActor func testBusyBookShortcutDoesNotNavigateOrDuplicate() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),store=WorkspaceStore(storage:root,readingDefaults:defaults()),w=store.addWorkspace();w.document=PDFDocument(url:file)!;w.sourceURL=file;w.busy=true
        let a=ReadingShortcut(path:file.path,title:"book",mode:.fixed,position:ViewPosition(selection:2));XCTAssertThrowsError(try store.openReadingShortcut(a));XCTAssertEqual(w.selection,0);XCTAssertEqual(store.tabs.count,1)
    }
    @MainActor func testCommandsExposeHistoryWithoutDocumentAndDisableUnsavedLinks() {
        let store=WorkspaceStore(readingDefaults:defaults());XCTAssertNil(store.unavailableReason(.readingHistory));XCTAssertNotNil(store.unavailableReason(.readingShortcut))
        XCTAssertTrue(FolioCommand.ranked(query:"阅读 记录",recent:[]).contains(.readingHistory));XCTAssertTrue(FolioCommand.ranked(query:"Dock",recent:[]).contains(.readingShortcut))
    }
    @MainActor func testUnsavedMergedDocumentCannotProduceBrokenShortcut() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let w=Workspace(storage:root,readingDefaults:defaults());w.document=PDFDocument(data:try Release027Tests().pdf(["unsaved"]))!
        XCTAssertFalse(w.canCreateReadingShortcut);XCTAssertThrowsError(try w.makeReadingShortcut(mode:.resume))
    }
    func testSymlinkAliasesShareOneHistoryRecordAndClearTogether() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults()
        let alias=root.appendingPathComponent("alias.pdf");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:file)
        ReadingProgress(last:2,date:Date(),pages:4).save(path:alias.path,defaults:suite)
        XCTAssertEqual(ReadingProgress.load(path:file.path,defaults:suite).last,2)
        XCTAssertEqual(ReadingProgress.history(defaults:suite).count,1)
        ReadingProgress.clear(path:file.path,defaults:suite);XCTAssertTrue(ReadingProgress.history(defaults:suite).isEmpty)
    }

    @MainActor func testSessionRestartPreservesPositionScaleAndSinglePageLayout() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults(),store=WorkspaceStore(storage:root,readingDefaults:suite),w=store.addWorkspace()
        w.document=PDFDocument(url:file)!;w.sourceURL=file;w.selection=2;w.readingPoint=CGPoint(x:12,y:345);w.readingScale=1.4;w.readingLayout = .single
        XCTAssertTrue(store.prepareToClose())
        let saved=try JSONDecoder().decode(Session.self,from:Data(contentsOf:root.appendingPathComponent("Session.json")))
        XCTAssertEqual(saved.entries.first?.layout,.single)
        let restarted=WorkspaceStore(storage:root,readingDefaults:suite);restarted.bootstrap();let opened=try XCTUnwrap(restarted.activeWorkspace);try await wait(opened)
        XCTAssertEqual(opened.selection,2);XCTAssertEqual(opened.readingPoint,CGPoint(x:12,y:345));XCTAssertEqual(opened.readingScale,1.4);XCTAssertEqual(opened.readingLayout,.single)
    }
    @MainActor func testOlderSessionRecoversLayoutFromReadingRecord() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),suite=defaults()
        ReadingProgress(last:3,date:Date(),pages:4,layout:.twoUp).save(path:file.path,defaults:suite)
        let session=Session(entries:[SessionEntry(slot:"",kind:.file,path:file.path,position:ViewPosition(selection:1,x:8,y:160,scale:1.2))],selected:"")
        try JSONEncoder().encode(session).write(to:root.appendingPathComponent("Session.json"))
        let store=WorkspaceStore(storage:root,readingDefaults:suite);store.bootstrap();let opened=try XCTUnwrap(store.activeWorkspace);try await wait(opened)
        XCTAssertEqual(opened.selection,1);XCTAssertEqual(opened.readingScale,1.2);XCTAssertEqual(opened.readingLayout,.twoUp)
    }

    @MainActor func testFinderColdLaunchQueuesShortcutUntilWorkspaceExists() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),shortcut=root.appendingPathComponent("book.kongfoliolink")
        try ReadingShortcut(path:file.path,title:"book",mode:.fixed,position:ViewPosition(selection:2,x:8,y:180,scale:1.4),layout:.single).write(to:shortcut)
        let router=ExternalDocumentRouter();router.receive([shortcut])
        let store=WorkspaceStore(storage:root,readingDefaults:defaults());router.attach(store);let opened=try XCTUnwrap(store.activeWorkspace);try await wait(opened)
        XCTAssertEqual(opened.selection,2);XCTAssertEqual(opened.readingLayout,.single);XCTAssertEqual(opened.readingScale,1.4);XCTAssertTrue(router.errors.isEmpty)
    }
    @MainActor func testDelegateAndSwiftUIURLDeliveryDoNotOpenDuplicateTabs() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),store=WorkspaceStore(storage:root,readingDefaults:defaults()),router=ExternalDocumentRouter(),time=Date()
        router.attach(store);router.receive([file],now:time);router.receive([file],now:time.addingTimeInterval(0.1))
        let opened=try XCTUnwrap(store.activeWorkspace);try await wait(opened);XCTAssertEqual(store.tabs.count,1)
    }
    @MainActor func testMalformedExternalLinkReportsErrorAndDoesNotReplaceBook() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),store=WorkspaceStore(storage:root,readingDefaults:defaults()),w=store.addWorkspace(),router=ExternalDocumentRouter()
        w.document=PDFDocument(url:file)!;w.sourceURL=file;w.selection=2;router.attach(store)
        router.receive([URL(string:"kongfolio://reading?ref=invalid")!]);XCTAssertEqual(router.errors.count,1);XCTAssertEqual(w.selection,2);XCTAssertEqual(store.tabs.count,1)
    }
    @MainActor func testBookmarkCanonicalPathReusesOriginalTabThroughSymbolicAlias() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)};let file=try book(root),alias=root.appendingPathComponent("alias.pdf"),store=WorkspaceStore(storage:root,readingDefaults:defaults()),w=store.addWorkspace()
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:file)
        w.document=PDFDocument(url:file)!;w.sourceURL=alias;w.selection=1
        let shortcut=ReadingShortcut(path:file.path,title:"book",mode:.fixed,position:ViewPosition(selection:2))
        let opened=try store.openReadingShortcut(shortcut);XCTAssertEqual(opened.id,w.id);XCTAssertEqual(store.tabs.count,1);XCTAssertEqual(w.selection,2)
    }

}
