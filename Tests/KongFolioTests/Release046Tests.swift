import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release046Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func pdf(_ folder:URL,name:String = "文献.pdf",pages:Int = 3) throws -> URL { let file = folder.appendingPathComponent(name);try SignaturePositionTests().document(pages:pages).dataRepresentation()!.write(to:file);return file }
    func note(_ text:String = "我的笔记") -> ReadingRecord { ReadingRecord(kind:.note,note:text) }
    @MainActor func wait(_ predicate:@escaping ()->Bool) async throws { for _ in 0..<300 { if predicate() { return };try await Task.sleep(nanoseconds:10_000_000) };throw FolioError(message:"等待验证条件超时") }
    func testFunctionToolbarBalancesRowsWithoutHidingActions() {
        for width:CGFloat in [480,600,800,1000,1400,1800] { let columns = FunctionToolbarLayout.columns(width:width,count:18);XCTAssertTrue(columns>0);XCTAssertTrue(columns*44<=Int(width-180));let rows = Int(ceil(18.0/Double(columns)));XCTAssertTrue(rows*columns>=18) }
    }
    func testLaunchPolicySelectsCurrentAndKeepsEmptyChoice() {
        let values = [SessionEntry(slot:"a",kind:.file),SessionEntry(slot:"b",kind:.file)]
        XCTAssertEqual(ReadingLaunchPolicy.current.entries(values,selected:"b").map(\.slot),["b"]);XCTAssertEqual(ReadingLaunchPolicy.all.entries(values,selected:nil),values);XCTAssertTrue(ReadingLaunchPolicy.empty.entries(values,selected:"a").isEmpty)
    }
    @MainActor func testCurrentStartupKeepsOtherTabsAvailableForLater() throws {
        let folder = try root(),a = try pdf(folder,name:"甲.pdf"),b = try pdf(folder,name:"乙.pdf"),defaults = UserDefaults(suiteName:"Launch046-"+UUID().uuidString)!
        defaults.set(ReadingLaunchPolicy.current.rawValue,forKey:ReadingLaunchPolicy.key)
        let session = Session(entries:[SessionEntry(slot:"a",kind:.file,path:a.path),SessionEntry(slot:"b",kind:.file,path:b.path,position:ViewPosition(selection:2))],selected:"b")
        try JSONEncoder().encode(session).write(to:folder.appendingPathComponent("Session.json"));let store = WorkspaceStore(storage:folder,readingDefaults:defaults);store.startupSafetyEnabled = false;store.bootstrap()
        XCTAssertEqual(store.startupEntries.map(\.slot),["a"]);XCTAssertEqual(store.tabs.compactMap(\.workspace).filter{$0.sourceURL != nil}.map(\.slot),["b"])
        store.saveSession();let saved = try XCTUnwrap(Session.decode(Data(contentsOf:folder.appendingPathComponent("Session.json"))));XCTAssertEqual(Set(saved.entries.map(\.slot)),Set(["a","b"]))
    }
    @MainActor func testEmptyStartupPreservesDeferredFiles() throws {
        let folder = try root(),file = try pdf(folder),defaults = UserDefaults(suiteName:"Empty046-"+UUID().uuidString)!;defaults.set(ReadingLaunchPolicy.empty.rawValue,forKey:ReadingLaunchPolicy.key)
        try JSONEncoder().encode(Session(entries:[SessionEntry(slot:"a",kind:.file,path:file.path)],selected:"a")).write(to:folder.appendingPathComponent("Session.json"))
        let store = WorkspaceStore(storage:folder,readingDefaults:defaults);store.startupSafetyEnabled = false;store.bootstrap();XCTAssertEqual(store.activeWorkspace?.count,0);XCTAssertEqual(store.startupEntries.count,1)
    }
    @MainActor func testIdleReleasePreservesPageAndDoesNotReleaseCurrentDocument() async throws {
        let folder = try root(),file = try pdf(folder),defaults = UserDefaults(suiteName:"Idle046-"+UUID().uuidString)!;defaults.set(30,forKey:"KongFolio.idleTabSeconds")
        let store = WorkspaceStore(storage:folder,readingDefaults:defaults),a = store.addWorkspace();a.load([file]);try await wait{a.count == 3 && !a.busy};a.selectPage(2);let b = store.addWorkspace();a.lastActive = Date().addingTimeInterval(-90);store.releaseIdleTabs();try await wait{a.count == 0};XCTAssertEqual(a.pendingView?.selection,2);XCTAssertEqual(store.selectedID,b.id)
        store.select(a.id);try await wait{a.count == 3 && !a.busy};XCTAssertEqual(a.selection,2)
    }
    @MainActor func testIdleReleaseProtectsUnsavedAndSplitDocuments() throws {
        let store = WorkspaceStore(storage:try root()),a = store.addWorkspace(),b = store.addWorkspace(),c = store.addWorkspace();store.readingDefaults.set(1,forKey:"KongFolio.idleTabSeconds")
        for w in [a,b,c] { w.document = SignaturePositionTests().document(pages:1);w.lastActive = Date.distantPast };a.dirty = true;c.splitPartner = b;store.releaseIdleTabs();XCTAssertEqual(a.count,1);XCTAssertEqual(b.count,1);XCTAssertEqual(c.count,1)
    }
    @MainActor func testReadQueueShowsDeferredCancelledAndLoadingStates() throws {
        let w = Workspace(storage:try root());w.sourceURL = URL(fileURLWithPath:"/tmp/待加载.pdf");w.needsLoad = true;XCTAssertTrue(w.openQueueStatus.contains("按需"));w.needsLoad = false;XCTAssertTrue(w.openQueueStatus.contains("取消"));w.isImporting = true;w.taskLabel = "等待 iCloud";XCTAssertEqual(w.openQueueStatus,"等待 iCloud");w.cancelImport();XCTAssertFalse(w.busy)
    }
    @MainActor func testSaveFailureRetainsTextAndRetryReallyWritesIt() async throws {
        let folder = try root(),blocked = folder.appendingPathComponent("ReadingJournal");try Data("阻塞目录".utf8).write(to:blocked);let j = ReadingJournal(storage:folder),r = note("尚未保存的中文");j.add(r)
        var failed = false;do { try await j.flush() } catch { failed = true };XCTAssertTrue(failed);XCTAssertTrue(j.dirty);XCTAssertEqual(j.record(r.id)?.note,r.note);XCTAssertNil(j.lastVerifiedSave)
        try FileManager.default.removeItem(at:blocked);try await j.flush();XCTAssertFalse(j.dirty);XCTAssertNotNil(j.lastVerifiedSave);XCTAssertEqual(ReadingJournal(storage:folder).record(r.id)?.note,r.note)
    }
    func testWriterRefusesToSilentlyReuseDifferentImageBytes() async throws {
        let folder = try root(),assets = folder.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);try Data("旧图".utf8).write(to:assets.appendingPathComponent("image.png"));let writer = ReadingJournalWriter()
        var failed = false;do { try await writer.write(ReadingJournalState(records:[note()]),revision:1,assets:["image.png":Data("新图".utf8)],folder:folder) } catch { failed = true };XCTAssertTrue(failed);XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent("image.png")),Data("旧图".utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("catalog.json").path))
    }
    func testEmergencyCopyWritesCurrentUnsavedCatalog() async throws {
        let folder = try root(),file = folder.appendingPathComponent("应急.zip"),r = note("未保存文字");try await ReadingEmergencyWriter.shared.write(ReadingJournalState(records:[r]),pending:[:],assets:folder,to:file,expected:FileBaseline(path:file.path,digest:nil));let unzip = folder.appendingPathComponent("unzip");try FileManager.default.createDirectory(at:unzip,withIntermediateDirectories:true);let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/ditto");process.arguments = ["-x","-k",file.path,unzip.path];try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0);let saved = try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:unzip.appendingPathComponent("ReadingJournal/catalog.json")));XCTAssertEqual(saved.records,[r])
    }
    func testSavedFilterRoundTripIncludesPageAndRecentConditions() throws {
        let folder = try root(),filter = SavedReadingFilter(name:"史料笔记",query:"民国",kind:"笔记",tag:"史料",topic:"专题",recent:true,page:3,size:20);try SavedReadingFilter.save([filter],folder:folder);XCTAssertEqual(try SavedReadingFilter.load(folder),[filter])
    }
    func testInvalidSavedFilterFileIsNotReplacedOnRead() throws {
        let folder = try root(),file = folder.appendingPathComponent("Filters.json"),bytes = Data("错误筛选".utf8);try bytes.write(to:file);XCTAssertThrowsError(try SavedReadingFilter.load(folder));XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    @MainActor func testRecentUntaggedSearchDoesNotIncludeOldOrRemovedRecords() async {
        var a = note("近期未整理"),b = note("旧笔记"),c = note("有标签"),d = note("删除");a.modified = Date();b.modified = Date.distantPast;c.tags = ["专题"];d.removed = Date()
        let result = await ReadingSearchWorker.shared.library(ReadingJournalState(records:[a,b,c,d]),request:ReadingSearchRequest(revision:0,recent:true,untagged:true));XCTAssertEqual(result.map(\.id),[.record(a.id)])
    }
    @MainActor func testTagMergeDeduplicatesNotesAndEssaysButKeepsFrozenCitation() throws {
        let j = ReadingJournal(storage:try root());var r = note();r.tags = ["近代","近代史"];j.add(r);let e = j.newEssay(title:"札记");j.editEssay(e) { $0.tags = ["近代"] };j.insert(r,in:e);try j.renameTag("近代",to:"近代史");XCTAssertEqual(j.record(r.id)?.tags,["近代史"]);XCTAssertEqual(j.essay(e)?.tags,["近代史"]);XCTAssertEqual(j.essay(e)?.blocks.last?.record?.tags,["近代","近代史"])
    }
    @MainActor func testTagSuggestionsReuseExistingNamesAndRejectCommaRename() throws {
        let j = ReadingJournal(storage:try root());var r = note();r.tags = ["民国史","思想史"];j.add(r);XCTAssertEqual(j.tagSuggestions("民国"),["民国史"]);XCTAssertThrowsError(try j.renameTag("民国史",to:"民国,近代"));XCTAssertEqual(j.record(r.id)?.tags,r.tags)
    }
    func testRelinkScanLeavesAmbiguousFileNamesForManualChoice() async throws {
        let folder = try root(),a = folder.appendingPathComponent("A"),b = folder.appendingPathComponent("B");try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true);_ = try pdf(a);_ = try pdf(b)
        var r = note();r.citations = [ReadingCitation(source:SourceRef(path:"/失效/文献.pdf",fileName:"文献.pdf",page:1),title:"文献")]
        let proposals = try await ReadingRelinkWorker.shared.scan(ReadingJournalState(records:[r]),folder:folder);XCTAssertEqual(proposals.count,1);XCTAssertEqual(proposals[0].candidates.count,2);XCTAssertEqual(proposals[0].requiredPage,1)
    }
    func testRelinkValidationRejectsFileWithTooFewPages() async throws {
        let folder = try root(),file = try pdf(folder,pages:1),row = ReadingRelinkProposal(old:"/old.pdf",candidates:[file],requiredPage:3)
        var failed = false;do { try await ReadingRelinkWorker.shared.validate([row.old:file],proposals:[row]) } catch { failed = true };XCTAssertTrue(failed)
    }
    @MainActor func testBatchRelinkKeepsQuotePageAndRectangle() throws {
        let folder = try root(),file = try pdf(folder),j = ReadingJournal(storage:folder);var r = note();r.quote = "引文";r.citations = [ReadingCitation(source:SourceRef(path:"/old.pdf",fileName:"原书",page:2,rects:[CGRect(x:1,y:2,width:3,height:4)],anchor:"引文"),title:"旧版本")];j.add(r);j.relinkBatch(["/old.pdf":file]);let updated = try XCTUnwrap(j.record(r.id));XCTAssertEqual(updated.quote,"引文");XCTAssertEqual(updated.citations[0].source.page,2);XCTAssertEqual(updated.citations[0].source.rects,r.citations[0].source.rects);XCTAssertEqual(updated.citations[0].source.path,file.path);XCTAssertEqual(updated.citations[0].title,"旧版本")
    }
    @MainActor func testReferenceTargetOpensExistingEssay() throws {
        let store = WorkspaceStore(storage:try root()),id = store.journal.newEssay(title:"引用札记"),reference = ReadingReference(id:"essay:"+id.uuidString,title:"札记",kind:"札记",removed:false,text:"");XCTAssertEqual(reference.item,.essay(id));store.openReadingItem(.essay(id));XCTAssertEqual(store.readingLibraryNavigation,.essay(id));XCTAssertEqual(store.journal.currentEssayID,id)
    }
    func testOutputReviewFindsMissingAssetsAndSourceMetadata() async throws {
        var r = note();r.imageAsset = "missing.png";r.citations = [ReadingCitation(source:SourceRef(path:"/missing.pdf",fileName:"缺失.pdf",page:0),title:"史料")]
        let issues = try await ReadingOutputReview.shared.inspect(ReadingExportSnapshot(title:"检查",records:[r]),assets:try root());XCTAssertTrue(issues.contains{$0.message.contains("图片缺失")});XCTAssertTrue(issues.contains{$0.message.contains("链接失效")});XCTAssertTrue(issues.contains{$0.message.contains("版本")});XCTAssertTrue(issues.allSatisfy{$0.item == .record(r.id)})
    }
    func testOutputReviewAcceptsValidCitationAndDetectsOutOfRangePage() async throws {
        let folder = try root(),file = try pdf(folder);var r = note();r.citations = [ReadingCitation(source:SourceRef(path:file.path,fileName:file.lastPathComponent,page:1,pageLabel:"二"),title:"史料",author:"作者",edition:"初版")]
        let good = try await ReadingOutputReview.shared.inspect(ReadingExportSnapshot(title:"检查",records:[r]),assets:folder);XCTAssertTrue(good.isEmpty)
        r.citations[0].author = ""
        r.citations[0].source.page = 9;let bad = try await ReadingOutputReview.shared.inspect(ReadingExportSnapshot(title:"检查",records:[r]),assets:folder);XCTAssertTrue(bad.first?.message.contains("超出") == true)
        XCTAssertTrue(bad.contains { $0.supplemental && $0.message.contains("作者") })
    }
    func testDeltaDistinguishesAddModifyAndDelete() throws {
        let a = note("旧甲"),b = note("旧乙"),old = ReadingJournalState(records:[a,b]),ledger = try ReadingExportLedger.capture(old);var changed = a;changed.note = "新甲";let c = note("新丙"),next = ReadingJournalState(records:[changed,c]),delta = try ReadingExportDelta(next,old:ledger)
        XCTAssertEqual(delta.added,["r:"+c.id.uuidString]);XCTAssertEqual(delta.modified,["r:"+a.id.uuidString]);XCTAssertEqual(delta.removed,["r:"+b.id.uuidString]);XCTAssertTrue(delta.report.contains("旧乙"));XCTAssertEqual(delta.snapshot(next,options:ReadingExportOptions()).records.count,2)
    }
    func testUnchangedDeltaIsEmptyAndSoftDeleteIsReported() throws {
        var r = note();let state = ReadingJournalState(records:[r]),old = try ReadingExportLedger.capture(state);XCTAssertFalse(try ReadingExportDelta(state,old:old).hasChanges);r.removed = Date();let deleted = try ReadingExportDelta(ReadingJournalState(records:[r]),old:old);XCTAssertEqual(deleted.removed,["r:"+r.id.uuidString]);XCTAssertTrue(deleted.added.isEmpty)
    }
    func testIncrementalSuccessExportsAllFormatsBeforeAdvancingLedger() async throws {
        let folder = try root(),journal = folder.appendingPathComponent("journal");try FileManager.default.createDirectory(at:journal,withIntermediateDirectories:true);let state = ReadingJournalState(records:[note("中文增量内容")]);let output = try await ReadingIncrementalWorker.shared.export(state,old:nil,options:ReadingExportOptions(),formats:[.word,.pdf,.markdown],assets:folder,journalFolder:journal,parent:folder)
        for name in ["新增与修改.docx","新增与修改.pdf","新增与修改.md","变更清单.md"] { XCTAssertTrue(FileManager.default.fileExists(atPath:output.appendingPathComponent(name).path)) };XCTAssertFalse(try ReadingExportDelta(state,old:ReadingExportLedger.load(journal)).hasChanges)
    }
    func testIncrementalFailedExportDoesNotAdvanceLedgerOrLeavePartialFolder() async throws {
        let folder = try root(),journal = folder.appendingPathComponent("journal");try FileManager.default.createDirectory(at:journal,withIntermediateDirectories:true);var r = note();r.imageAsset = "missing.png"
        var failed = false;do { _ = try await ReadingIncrementalWorker.shared.export(ReadingJournalState(records:[r]),old:nil,options:ReadingExportOptions(),formats:[.word],assets:folder,journalFolder:journal,parent:folder) } catch { failed = true };XCTAssertTrue(failed);XCTAssertNil(try ReadingExportLedger.load(journal));XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:folder.path).contains{$0.hasPrefix("KongFolio-增量-")})
    }
    func testDeletionOnlyIncrementalWritesChangeListWithoutEmptyDocuments() async throws {
        let folder = try root(),journal = folder.appendingPathComponent("journal");try FileManager.default.createDirectory(at:journal,withIntermediateDirectories:true);let old = try ReadingExportLedger.capture(ReadingJournalState(records:[note("应在删除清单") ]));try JSONEncoder().encode(old).write(to:journal.appendingPathComponent("ExportLedger.json"));let output = try await ReadingIncrementalWorker.shared.export(ReadingJournalState(),old:old,options:ReadingExportOptions(),formats:[.word],assets:folder,journalFolder:journal,parent:folder);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:output.path),["变更清单.md"]);XCTAssertTrue(try String(contentsOf:output.appendingPathComponent("变更清单.md")).contains("应在删除清单"))
    }
    func testStaleOrCorruptIncrementalLedgerStopsWithoutOverwrite() async throws {
        let folder = try root(),file = folder.appendingPathComponent("ExportLedger.json"),bytes = Data("损坏的导出基准".utf8);try bytes.write(to:file);XCTAssertThrowsError(try ReadingExportLedger.load(folder));var failed = false;do { _ = try await ReadingIncrementalWorker.shared.export(ReadingJournalState(records:[note()]),old:nil,options:ReadingExportOptions(),formats:[.markdown],assets:folder,journalFolder:folder,parent:folder) } catch { failed = true };XCTAssertTrue(failed);XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testAncientOCRColumnsOrderPreservesTraditionalCharacters() {
        let lines = [RecognizedLine(text:"國",box:CGRect(x:0.7,y:0.7,width:0.1,height:0.1)),RecognizedLine(text:"學",box:CGRect(x:0.7,y:0.5,width:0.1,height:0.1)),RecognizedLine(text:"史",box:CGRect(x:0.3,y:0.7,width:0.1,height:0.1))]
        let segments = ReadingOCRSegments.make(lines,vertical:true);XCTAssertEqual(segments.map(\.text),["國學","史"]);XCTAssertEqual(ReadingOCRSegments.ordered(segments,by:.leftToRight).map(\.text),["史","國學"]);XCTAssertEqual(segments[0].original,"國學")
    }
    @MainActor func testOCRCorrectionSegmentsAndOriginalSurviveReopen() async throws {
        let folder = try root(),j = ReadingJournal(storage:folder);var r = note();r.originalOCR = "國學";r.quote = "國學校訂";r.ocrSegments = [ReadingOCRSegment(text:"國學校訂",original:"國學",box:CGRect(x:0,y:0,width:1,height:1))];j.add(r);try await j.flush();let reopened = ReadingJournal(storage:folder);XCTAssertEqual(reopened.record(r.id)?.ocrSegments,r.ocrSegments);XCTAssertEqual(reopened.record(r.id)?.originalOCR,"國學")
    }
    func testOldRecordsDecodeWithoutOCRSegments() throws {
        let r = note();let data = try JSONEncoder().encode(r);XCTAssertNil(try JSONDecoder().decode(ReadingRecord.self,from:data).ocrSegments)
    }
    @MainActor func testMarkedChineseTextIgnoresRefreshUntilCandidateCommitted() {
        var value = "第一行\n第二行";let view = ComposingTextView(),coordinator = StableInputCoordinator(read:{value},write:{value = $0});view.string = value;view.isRichText = false;view.delegate = coordinator;view.committed = { coordinator.publish($0) };view.setSelectedRange(NSRange(location:3,length:0));view.setMarkedText("zhongwen",selectedRange:NSRange(location:8,length:0),replacementRange:NSRange(location:NSNotFound,length:0));coordinator.synchronize(view);XCTAssertTrue(view.hasMarkedText());XCTAssertEqual(value,"第一行\n第二行");view.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0));view.unmarkText();XCTAssertEqual(value,"第一行中文\n第二行");XCTAssertEqual(view.selectedRange().location,5);view.finishEditingSession()
    }
    @MainActor func testRepeatedChineseCommitAndModelEchoNeverMovesFirstLineToSecond() {
        var value = "- 第一项\n- 第二项";let view = ComposingTextView(),coordinator = StableInputCoordinator(read:{value},write:{value = $0});view.string = value;view.isRichText = false;view.supportsMarkdownLists = true;view.delegate = coordinator;view.committed = { coordinator.publish($0) };view.setSelectedRange(NSRange(location:3,length:0))
        for _ in 0..<30 { view.setMarkedText("wen",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0));coordinator.synchronize(view);view.insertText("文",replacementRange:NSRange(location:NSNotFound,length:0));view.unmarkText();let selected = view.selectedRange();coordinator.synchronize(view);XCTAssertEqual(view.selectedRange(),selected);XCTAssertEqual(view.string.components(separatedBy:"\n")[1],"- 第二项") };XCTAssertEqual(value.components(separatedBy:"\n")[0],"- 第"+String(repeating:"文",count:30)+"一项");view.finishEditingSession()
    }
    @MainActor func testEmergencyDirectoryImportsAsPreviewThenRestoresSelectedText() async throws {
        let root = try root(),source = root.appendingPathComponent("external"),live = root.appendingPathComponent("live");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let r = note("应急文字");try JSONEncoder().encode(ReadingJournalState(records:[r])).write(to:source.appendingPathComponent("catalog.json"));let journal = ReadingJournal(storage:live)
        let backup = try ReadingBackupStorage.importEmergency(source,folder:journal.folder);XCTAssertTrue(journal.state.records.isEmpty);XCTAssertEqual(try ReadingBackupStorage.read(backup.id,folder:journal.folder).state.records,[r]);try await journal.restoreBackup(backup.id,ids:[.record(r.id)]);XCTAssertEqual(journal.record(r.id)?.note,"应急文字")
    }
    func testCorruptEmergencyDirectoryDoesNotTouchLiveCatalog() throws {
        let folder = try root(),source = folder.appendingPathComponent("external");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true);try Data("坏记录".utf8).write(to:source.appendingPathComponent("catalog.json"));XCTAssertThrowsError(try ReadingBackupStorage.importEmergency(source,folder:folder.appendingPathComponent("live")));XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("live/catalog.json").path))
    }

    @MainActor func testRepeatedNavigationToSameRecordHasIndependentRequestIdentity() throws {
        let store = WorkspaceStore(storage:try root()),r = note();store.journal.add(r);store.openReadingItem(.record(r.id));let first = store.readingLibraryNavigationRequest;store.openReadingItem(.record(r.id));XCTAssertFalse(first == store.readingLibraryNavigationRequest);XCTAssertEqual(store.readingLibraryNavigation,.record(r.id));XCTAssertEqual(store.journal.state.records.count,1)
    }

}
