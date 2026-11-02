import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release049Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    @MainActor func testStopBatchKeepsLoadedFilesAndAllowsExplicitRetry() throws {
        let root = try root(),h = Release046Tests(),files = try (0..<20).map{try h.pdf(root,name:"书\($0).pdf")},s = WorkspaceStore(storage:root)
        s.openEach(files);s.stopRemainingBatch()
        XCTAssertFalse(s.canStopOpenBatch);XCTAssertEqual(s.openBatchDocuments.count,20);XCTAssertTrue(s.openBatchDocuments.allSatisfy{!$0.needsLoad && !$0.isImporting})
        let w = s.openBatchDocuments[5];w.document = SignaturePositionTests().document(pages:1);s.stopRemainingBatch();XCTAssertEqual(w.count,1);XCTAssertTrue(s.openBatchSummary.contains("已载入 1"));XCTAssertNotNil(w.sourceURL)
        s.openEach(files);XCTAssertEqual(s.openBatchDocuments.count,20);XCTAssertTrue(s.openBatchIDs.contains(w.id));XCTAssertTrue((s.activeWorkspace?.count ?? 0)>0 || s.activeWorkspace?.busy == true);s.stopRemainingBatch()
        let single=WorkspaceStore(storage:try self.root());single.openEach([files[0]]);single.closeActive();XCTAssertTrue(single.openBatchDocuments.isEmpty)
    }
    @MainActor func testCloseClearsBackgroundHandlesAndBreaksSplitCycle() throws {
        let root = try root(),a = Workspace(storage:root),b = Workspace(storage:root);a.document = SignaturePositionTests().document(pages:1);a.splitPartner = b;b.splitPartner = a
        a.searchTask = Task { [] };a.estimateTask = Task { throw CancellationError() };a.comparison = SignaturePositionTests().document(pages:1);a.error = "上次错误"
        a.clearDocument(keepingSource:false);XCTAssertNil(a.splitPartner);XCTAssertNil(a.searchTask);XCTAssertNil(a.estimateTask);XCTAssertNil(a.comparison);XCTAssertNil(a.error);b.splitPartner = nil
    }
    @MainActor func testUnloadKeepsPendingLayout() throws { let w = Workspace(storage:try root());w.pendingReadingLayout = .continuous;w.clearDocument(keepingSource:true);XCTAssertEqual(w.pendingReadingLayout,.continuous) }
    @MainActor func testEditorDismantlePublishesFinalTextButNotMarkedText() {
        let v = ComposingTextView();v.string = "已输入";var values:[String] = [];v.committed = { values.append($0.string) };v.finishEditingSession();XCTAssertEqual(values,["已输入"])
        let marked = ComposingTextView();marked.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:0,length:0));marked.committed = { values.append($0.string) };marked.finishEditingSession();XCTAssertEqual(values.count,1)
    }
    @MainActor func testChineseCompositionAndListInputKeepsFirstLineAndUndo() {
        var value = "首行\n- 一项";let c = StableInputCoordinator(read:{value},write:{value=$0}),v = ComposingTextView();v.string=value;v.isRichText=false;v.allowsUndo=true;v.delegate=c;v.committed={c.publish($0)};v.supportsMarkdownLists=true
        v.setSelectedRange(NSRange(location:0,length:0));v.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:0,length:0));c.synchronize(v);XCTAssertEqual(value,"首行\n- 一项");v.insertText("中",replacementRange:v.markedRange());XCTAssertEqual(value,"中首行\n- 一项")
        v.unmarkText();v.breakUndoCoalescing();v.undoManager?.removeAllActions()
        v.setSelectedRange(NSRange(location:v.string.utf16.count,length:0));v.insertNewline(nil)
        XCTAssertTrue(v.string.hasSuffix("\n- "),v.string)
        XCTAssertEqual(v.string,value)
        v.undoManager?.undo();XCTAssertEqual(v.string,"中首行\n- 一项")
    }
    func testLibrarySessionRestoresSearchAndPage() { let d=UserDefaults(suiteName:UUID().uuidString)!,s=ReadingLibrarySession(query:"史料",kind:"笔记",tag:"清代",page:3,size:20);s.save(d);XCTAssertEqual(ReadingLibrarySession.load(d),s) }
    func testLibraryResultsCarrySourceAndSearchContext() { let r=ReadingRecord(kind:.note,note:"某书中的史料片段",citations:[ReadingCitation(source:SourceRef(path:"/x.pdf",fileName:"某书",page:5),title:"某书")]),i=ReadingLibraryItem.record(r);XCTAssertTrue(i.sourceSummary.contains("第 6 页"));XCTAssertTrue(i.matchingContext("史料")?.contains("史料") == true) }
    func testQuoteToolsAreOptInAndKeepParagraphsAndOriginalGlyphs() { let s="國學\n文獻\n\nLatin\nwords";XCTAssertEqual(ReadingQuoteTools.preview(s,script:.unchanged,joinLines:false),s);XCTAssertEqual(ReadingQuoteTools.preview(s,script:.unchanged,joinLines:true),"國學文獻\n\nLatin words");XCTAssertEqual(ReadingQuoteTools.preview("文献",script:.traditional,joinLines:false),"文獻") }
    @MainActor func testQuoteCorrectionPreservesOriginalAndRejectsStalePreview() throws { let j=ReadingJournal(storage:try root()),r=ReadingRecord(kind:.excerpt,quote:"原摘录");j.add(r);try j.applyQuoteCorrection(r,text:"校订");XCTAssertEqual(j.record(r.id)?.originalQuote,"原摘录");XCTAssertThrowsError(try j.applyQuoteCorrection(r,text:"旧预览"));XCTAssertEqual(j.record(r.id)?.quote,"校订") }
    @MainActor func testReadingCitationCapturesKnownSourceFingerprint() throws { let root=try root(),w=Workspace(storage:root),url=try Release046Tests().pdf(root);w.load([url]);XCTAssertEqual(w.readingCitation().source.fingerprint,w.fileBaseline?.digest) }
    func testExportTemplateKeepsFormatAndDecodesOldTemplate() throws { let d=UserDefaults(suiteName:UUID().uuidString)!,p=ReadingExportProfile(name:"常用",format:.markdown,options:ReadingExportOptions());try ReadingExportProfile.save([p],defaults:d);XCTAssertEqual(ReadingExportProfile.load(defaults:d).first?.format,.markdown);let old=try JSONDecoder().decode(ReadingExportProfile.self,from:Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"旧模板","options":{"fontName":"Songti SC","fontSize":12,"includeQuote":true,"includeNote":true,"includeSources":true}}"#.utf8));XCTAssertNil(old.format) }
    @MainActor func testAllExportFormatsReopenAndKeepRecords() throws { let root=try root(),snap=ReadingExportSnapshot(title:"阅读汇编",records:[ReadingRecord(kind:.excerpt,quote:"第一条史料"),ReadingRecord(kind:.note,note:"第二条笔记")]);for kind in ReadingRecordExport.Format.allCases { let file=root.appendingPathComponent("结果."+kind.ext);try ReadingRecordExport.write(snap,format:kind,assets:root,to:file,expected:FileBaseline(path:file.path,digest:nil));try ReadingExportAudit.validate(file,format:kind,snapshot:snap);if kind == .pdf { let extracted = PDFDocument(url:file)?.string ?? "",compact = ReadingServices.repairIdeographs(extracted).filter{!$0.isWhitespace};print("EXPORT_AUDIT_PDF "+extracted.debugDescription);XCTAssertTrue(compact.contains("第一条史料") && compact.contains("第二条笔记"),"PDF extracted text: "+extracted) };if kind == .word { let entries=try ReadingExportAudit.storedZIP(Data(contentsOf:file));XCTAssertTrue(String(data:entries["word/document.xml"]!,encoding:.utf8)!.contains("第二条笔记"),"Word must retain the note text") };if kind == .markdown { XCTAssertTrue(try String(contentsOf:file).contains("第二条笔记"),"Markdown must retain the note text") } } }
    func testExportAuditRejectsCorruptWordAndEmptyPDF() throws { let root=try root(),file=root.appendingPathComponent("bad"),snap=ReadingExportSnapshot(title:"测试");try Data().write(to:file);XCTAssertThrowsError(try ReadingExportAudit.validate(file,format:.pdf,snapshot:snap));try Data("PKbad".utf8).write(to:file);XCTAssertThrowsError(try ReadingExportAudit.validate(file,format:.word,snapshot:snap)) }
    @MainActor func testBackupRoundTripRestoresSignaturesSettingsAndRecordsWithoutOverwritingExistingSettings() async throws {
        let root=try root(),storage=root.appendingPathComponent("data"),d=UserDefaults(suiteName:UUID().uuidString)!,r=ReadingRecord(kind:.note,note:"备份笔记"),j=ReadingJournal(storage:storage);j.add(r);try await j.flush();try SignatureLibrary.write([SignatureTemplate(name:"我的签名",pdf:Data([1,2,3]))],storage:storage);d.set(2,forKey:"KongFolio.maximumLoadedTabs")
        let b=try ResearchBackup.capture(storage:storage,catalog:BookLibrary(storage:storage).catalog,research:ResearchStore(storage:storage).state,progress:[:],includeOriginals:false,settings:PersonalReadingBackup.settings(d));let file=root.appendingPathComponent("backup");try b.write(file,expected:FileBaseline(path:file.path,digest:nil));let checked=try ResearchBackup.read(file),restored=try checked.restore(in:root),support=restored.root.appendingPathComponent("AppData"),other=root.appendingPathComponent("other"),d2=UserDefaults(suiteName:UUID().uuidString)!
        d2.set(4,forKey:"KongFolio.maximumLoadedTabs");try PersonalReadingBackup.merge(from:support.appendingPathComponent("Personal"),storage:other,defaults:d2);XCTAssertEqual(try SignatureLibrary.read(storage:other).first?.name,"我的签名");XCTAssertEqual(d2.integer(forKey:"KongFolio.maximumLoadedTabs"),4);XCTAssertEqual(ReadingJournal(storage:support).record(r.id)?.note,"备份笔记");XCTAssertEqual(j.record(r.id)?.note,"备份笔记")
    }
    @MainActor func testOutputReviewReportsChangedOriginalFingerprint() async throws {
        let root=try root(),file=try Release046Tests().pdf(root),r=ReadingRecord(kind:.excerpt,quote:"引文",citations:[ReadingCitation(source:SourceRef(path:file.path,fileName:"原书",page:0,fingerprint:String(repeating:"0",count:64)),title:"原书")])
        let issues=try await ReadingOutputReview.shared.inspect(ReadingExportSnapshot(title:"汇编",records:[r]),assets:root)
        XCTAssertTrue(issues.contains{$0.message.contains("原文内容已变化")})
    }
    func testPersonalBackupRejectsUnexpectedPathsAndKeys() throws { let data=try PropertyListSerialization.data(fromPropertyList:["UnrelatedKey":"x"],format:.binary,options:0);XCTAssertThrowsError(try PersonalReadingBackup.validate([ResearchBackup.Asset(path:"Personal/Settings.plist",bytes:data,digest:"")]));XCTAssertThrowsError(try PersonalReadingBackup.validate([ResearchBackup.Asset(path:"Personal/unknown",bytes:Data(),digest:"")])) }
}
