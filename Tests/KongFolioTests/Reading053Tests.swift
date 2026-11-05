import XCTest
import Foundation
@testable import KongFolio

@MainActor final class Reading053Tests: XCTestCase {
    func folder()throws->URL { let u=FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio053-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u }
    func citation(_ page:Int=0)->ReadingCitation { ReadingCitation(source:SourceRef(path:"/generated/book.pdf",fileName:"book.pdf",page:page),title:"近代史料",author:"作者甲") }
    func testConcurrentDisjointEditsRetainBoth() {
        let r=ConcurrentText053.merge(base:"甲乙丙丁",local:"甲新乙丙丁",external:"甲乙丙新丁")
        XCTAssertEqual(r.text,"甲新乙丙新丁");XCTAssertFalse(r.conflict)
    }
    func testConcurrentOverlappingEditsRetainVersions() {
        let r=ConcurrentText053.merge(base:"旧文",local:"新甲",external:"新乙")
        XCTAssertTrue(r.conflict);XCTAssertTrue(r.text.contains("新甲"));XCTAssertTrue(r.text.contains("新乙"))
    }
    func testConcurrentCompositionUnicodeBoundaries() {
        XCTAssertEqual(ConcurrentText053.merge(base:"甲📝乙",local:"甲📖乙",external:"前甲📝乙").text,"前甲📖乙")
    }
    func testConcurrentModelEchoDoesNotDuplicate() { XCTAssertEqual(ConcurrentText053.merge(base:"甲",local:"甲乙",external:"甲乙").text,"甲乙") }
    func testIncrementalReopenRetainsCurrentState() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var s=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"第一版")])
        try ReadingDeltaStorage.checkpoint(s,folder:f);s.records[0].note="第二版"
        _=try ReadingDeltaStorage.append(s,folder:f)
        XCTAssertEqual(try ReadingDeltaStorage.read(f).state,s)
        let legacy=try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:f.appendingPathComponent("catalog.json")))
        XCTAssertEqual(legacy.records[0].note,"第一版")
        try ReadingDeltaStorage.checkpoint(s,folder:f)
        XCTAssertEqual(try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:f.appendingPathComponent("catalog.json"))),s)
    }
    func testIncrementalWritesOnlyChangedRecord() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var s=ReadingJournalState(records:(0..<250).map{ReadingRecord(kind:.note,note:"笔记 \($0)")})
        try ReadingDeltaStorage.checkpoint(s,folder:f);s.records[100].note="修改内容";_=try ReadingDeltaStorage.append(s,folder:f)
        let active=try ReadingDeltaStorage.active(f),files=try FileManager.default.contentsOfDirectory(at:active.appendingPathComponent("Transactions"),includingPropertiesForKeys:nil)
        let env=try JSONDecoder().decode(ReadingDeltaStorage.Envelope.self,from:Data(contentsOf:files[0])),delta=try JSONDecoder().decode(ReadingDeltaStorage.Delta.self,from:env.payload)
        XCTAssertEqual(delta.records.count,1);XCTAssertEqual(delta.records[0].id,s.records[100].id)
    }
    func testIncrementalTamperingNeverSilentlyDropsRecords() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var s=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"保存前")]);try ReadingDeltaStorage.checkpoint(s,folder:f);s.records[0].note="保存后";_=try ReadingDeltaStorage.append(s,folder:f)
        let dir=try ReadingDeltaStorage.active(f).appendingPathComponent("Transactions"),file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first)
        try Data("坏数据".utf8).write(to:file)
        XCTAssertThrowsError(try ReadingDeltaStorage.read(f))
    }
    func testConcurrentWritersRejectStaleGeneration() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var s=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"旧")]);try ReadingDeltaStorage.checkpoint(s,folder:f)
        let cached=try ReadingDeltaStorage.read(f);s.records[0].note="另一个写入者";try ReadingDeltaStorage.checkpoint(s,folder:f)
        XCTAssertThrowsError(try ReadingDeltaStorage.append(cached.state,folder:f,cached:cached))
    }
    func testRecordHistoryCanRestoreOneRecord() async throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let journal=ReadingJournal(storage:f),r=ReadingRecord(kind:.note,note:"旧文")
        journal.add(r);try await journal.flush();journal.editRecord(r.id){$0.note="新文"};try await journal.flush()
        let history=try ReadingRecordHistory.read("r-"+r.id.uuidString,folder:journal.folder)
        XCTAssertEqual(history.first?.record?.note,"旧文");journal.restoreRevision053(try XCTUnwrap(history.first));XCTAssertEqual(journal.record(r.id)?.note,"旧文")
    }
    func testBooleanChineseAndOrExclusion() {
        let q=ReadingSearchExpression053("甲 乙 或 丙 -丁")
        XCTAssertTrue(q.matches("甲和乙",exact:false));XCTAssertTrue(q.matches("丙",exact:false));XCTAssertFalse(q.matches("丙丁",exact:false));XCTAssertFalse(q.matches("只有甲",exact:false))
    }
    func testQuotedPhraseAndCompatibilityGlyphs() {
        XCTAssertTrue(ReadingSearchExpression053("\"中國文獻\"").matches("中 國 文 獻",exact:false))
        XCTAssertFalse(ReadingSearchExpression053("中國").matches("中 國",exact:true))
        XCTAssertTrue(ReadingSearchExpression053("崎").matches("﨑",exact:false))
    }
    func testSearchFieldScopesDoNotCrossMatch() async {
        let r=ReadingRecord(kind:.note,quote:"原文关键词",note:"我的想法",citations:[citation()]),s=ReadingJournalState(records:[r]);var o=ReadingLibraryOptions053();o.scope = .mine
        let result=await ReadingSearchWorker.shared.library(s,request:ReadingSearchRequest(revision:1,query:"原文",options053:o));XCTAssertTrue(result.isEmpty)
        o.scope = .quote
        let found=await ReadingSearchWorker.shared.library(s,request:ReadingSearchRequest(revision:1,query:"原文",options053:o));XCTAssertEqual(found.count,1)
    }
    func testIndexWorksAcrossKindFiltersAtSameRevision() async throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let s=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"共同词语甲"),ReadingRecord(kind:.excerpt,quote:"共同词语乙")]),o=ReadingLibraryOptions053()
        let a=await ReadingSearchWorker.shared.library(s,request:ReadingSearchRequest(revision:1,query:"共同",kind:"笔记",options053:o,indexFolder:f.path))
        let b=await ReadingSearchWorker.shared.library(s,request:ReadingSearchRequest(revision:1,query:"共同",kind:"摘录",options053:o,indexFolder:f.path))
        XCTAssertEqual(a.count,1);XCTAssertEqual(b.count,1)
    }
    func testPageAuthorDateFiltersRequireSameCitation() {
        let item=ReadingLibraryItem.record(ReadingRecord(kind:.excerpt,quote:"文",citations:[citation(9)]));var o=ReadingLibraryOptions053();o.author="作者甲";o.firstPage=10;o.lastPage=10
        XCTAssertTrue(item.filtered053(o));o.lastPage=9;XCTAssertFalse(item.filtered053(o))
    }
    func testDeepLinksValidateKindAndPreserveIdentity() {
        let id=ReadingLibraryID.record(UUID());XCTAssertEqual(ReadingRecordLink053.parse(ReadingRecordLink053.url(id)),id)
        XCTAssertNil(ReadingRecordLink053.parse(URL(string:"kongfolio://record?id="+id.uuid053.uuidString+"&kind=unknown")!))
    }
    func testPageRemovalRetainsOriginalLocationAndDisablesWrongJump() {
        let f=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:f)}
        let journal=ReadingJournal(storage:f),r=ReadingRecord(kind:.excerpt,quote:"引用",citations:[citation(1)]);journal.add(r)
        journal.remapSources053(path:"/generated/book.pdf",order:[0,2])
        XCTAssertEqual(journal.record(r.id)?.citations[0].tracking?.capturedPage,1);XCTAssertEqual(journal.record(r.id)?.citations[0].source.invalidPage053,true)
    }
    func testPageInsertionMovesCurrentButKeepsCapturedPage() {
        let f=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:f)}
        let journal=ReadingJournal(storage:f),r=ReadingRecord(kind:.excerpt,quote:"引用",citations:[citation(1)]);journal.add(r);journal.remapSources053(path:"/generated/book.pdf",order:[-1,0,1])
        XCTAssertEqual(journal.record(r.id)?.citations[0].source.page,2);XCTAssertEqual(journal.record(r.id)?.citations[0].tracking?.capturedPage,1)
    }
    func testMetadataPreviewRejectsConcurrentChanges() {
        let f=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:f)}
        let journal=ReadingJournal(storage:f),r=ReadingRecord(kind:.note,note:"笔记",citations:[citation()]);journal.add(r);let expected=journal.state;journal.editRecord(r.id){$0.note="又修改了"}
        XCTAssertThrowsError(try journal.updateBookMetadata053(path:"/generated/book.pdf",publication:ReadingPublication053(),author:"新作者",title:"新书名",expected:expected))
    }
    func testDuplicateMergePreservesNotesSourcesAndRecovery() throws {
        let f=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:f)}
        let journal=ReadingJournal(storage:f),a=ReadingRecord(kind:.excerpt,quote:"共同原文",note:"甲笔记",citations:[citation()]),b=ReadingRecord(kind:.excerpt,quote:"共同原文",note:"乙笔记",citations:[citation()]);journal.add(a);journal.add(b)
        try journal.mergeDuplicates053([a.id,b.id]);XCTAssertTrue(journal.record(a.id)?.note.contains("乙笔记") == true);XCTAssertNotNil(journal.record(b.id)?.removed);try journal.undoBulk();XCTAssertNil(journal.record(b.id)?.removed)
    }
    func testFrozenQuotationDoesNotFollowSilentEdit() throws {
        let f=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:f)}
        let journal=ReadingJournal(storage:f),a=ReadingRecord(kind:.note,note:"旧正文"),b=ReadingRecord(kind:.note,note:"目标笔记");journal.add(a);journal.add(b);try journal.quote053(.record(a),in:.record(b.id));journal.editRecord(a.id){$0.note="新正文"}
        XCTAssertEqual(journal.record(b.id)?.extras?.quotations?.first?.text,"旧正文")
    }
    func testCSVQuotesLinebreaksAndFullProvenance() {
        let r=ReadingRecord(kind:.note,title:"甲,\"乙\"",note:"第一行\n第二行",citations:[citation()])
        let text=ReadingCatalog053.csv([.record(r)],columns:[.title,.note,.source]);XCTAssertTrue(text.contains("\"甲,\"\"乙\"\"\""));XCTAssertTrue(text.contains("第一行\n第二行"));XCTAssertTrue(text.contains("作者甲"))
    }
    func testStableMarkdownFilenameSurvivesTitleChanges() { let id=ReadingLibraryID.record(UUID());XCTAssertTrue(id.filename053.hasPrefix("record-"));XCTAssertEqual(id.filename053,id.filename053) }
    func testReadableBackupReopenAndReplace() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var s=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"原笔记",citations:[citation()])]);let assets=f.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
        let output=try ReadingReadable053.write(s,assets:assets,to:f);let file=output.appendingPathComponent(ReadingLibraryID.record(s.records[0].id).filename053)
        XCTAssertTrue(try String(contentsOf:file).contains("原笔记"));s.records[0].note="改过的笔记";_=try ReadingReadable053.write(s,assets:assets,to:f);XCTAssertTrue(try String(contentsOf:file).contains("改过的笔记"))
    }
    func testExtraAssetPathsAreValidated() {
        let r=ReadingRecord(kind:.image,extras:ReadingRecordExtras053(visualAsset:"../outside.png"));XCTAssertThrowsError(try ReadingJournalState(records:[r]).validate())
    }
    func testToolbarKeepsSearchAndPDFEditingInOneRowPolicy() { let p=ReaderToolbarProfile();XCTAssertTrue(p.visible(width:800).contains(.search));XCTAssertTrue(p.visible(width:800).contains(.pdfPages));XCTAssertEqual(p.visible(width:800).count+p.hidden(width:800).count,FileToolbarAction.allCases.count) }
}
