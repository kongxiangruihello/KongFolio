import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release045Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func record(_ text:String = "第一段\n\n第二段") -> ReadingRecord { ReadingRecord(kind:.note,note:text,citations:[ReadingCitation(source:SourceRef(path:"/原书.pdf",fileName:"原书.pdf",page:8,pageLabel:"五"),title:"史料",author:"作者",edition:"初版")]) }
    func applied(_ edit:TextEdit?,to text:String) throws -> String { let edit = try XCTUnwrap(edit);return (text as NSString).replacingCharacters(in:edit.range,with:edit.replacement) }
    @MainActor func testSignatureLibrarySurvivesRestartAndStaleTabsCannotOverwriteIt() throws {
        let folder = try root(),store = WorkspaceStore(storage:folder),a = store.addWorkspace(),b = store.addWorkspace(),image = SignaturePositionTests().square()
        let first = try XCTUnwrap(a.addSignatureImage(image,name:"签名甲"));XCTAssertEqual(b.signatures.count,1)
        b.signatures = [] // A tab opened before the import must merge the durable file, not its old array.
        let second = try XCTUnwrap(b.addSignatureImage(image,name:"签名乙"));a.renameSignature(first.id,to:"新名称")
        let reopened = Workspace(storage:folder);reopened.bootstrap(restoreRecovery:false)
        XCTAssertEqual(reopened.signatures.count,2);XCTAssertTrue(reopened.signatures.contains{$0.id == first.id && $0.name == "新名称"});XCTAssertTrue(reopened.signatures.contains{$0.id == second.id})
        b.removeSignature(first.id);XCTAssertEqual(try SignatureLibrary.read(storage:folder).map(\.id),[second.id]);XCTAssertEqual(a.signatures.count,1)
    }
    @MainActor func testCorruptSignatureLibraryIsPreservedAndImportReportsFailure() throws {
        let folder = try root(),file = folder.appendingPathComponent("Signatures.json"),bytes = Data("损坏的原库".utf8);try bytes.write(to:file)
        let workspace = Workspace(storage:folder);XCTAssertNil(workspace.addSignatureImage(SignaturePositionTests().square(),name:"不应假称保存"));XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertNotNil(workspace.error)
    }
    @MainActor func testSignatureManagementWorksFromATextTabAndRefreshesOpenPDFTabs() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = WorkspaceStore(storage:folder)
        let pdf = store.addWorkspace()
        let existing = try XCTUnwrap(pdf.addSignatureImage(SignaturePositionTests().square(),name:"原签名"))
        _ = store.newNote()
        XCTAssertNil(store.commandWorkspace)

        let imported = SignatureTemplate(name:"新签名",pdf:Data(),image:existing.image)
        let renamed = try store.editManagedSignatures {
            $0[0].name = "已改名"
            $0.append(imported)
        }
        XCTAssertEqual(renamed.map(\.name),["已改名","新签名"])
        XCTAssertEqual(pdf.signatures.map(\.name),renamed.map(\.name))
        let remaining = try store.editManagedSignatures { $0.removeAll { $0.id == existing.id } }
        XCTAssertEqual(remaining.map(\.id),[imported.id])
        XCTAssertEqual(try SignatureLibrary.read(storage:folder).map(\.id),[imported.id])
    }

    @MainActor func testSignatureImageReallyRemainsInSavedPDFWithoutLocalMetadata() throws {
        let folder = try root(),workspace = Workspace(storage:folder);workspace.document = SignaturePositionTests().document(pages:1)
        let image = SignaturePositionTests().square(),template = try XCTUnwrap(workspace.addSignatureImage(image,name:"持久签名")),view = SignaturePositionTests.StubView();workspace.pdfView = view
        view.target = (workspace.document.page(at:0)!,CGRect(x:40,y:40,width:60,height:30));let file = folder.appendingPathComponent("签名保存.pdf");try XCTUnwrap(workspace.document.dataRepresentation()).write(to:file);workspace.sourceURL = file;workspace.fileBaseline = try FileBaseline.capture(file);workspace.beginPlacing(template);XCTAssertTrue(workspace.saveDirectly());XCTAssertNil(workspace.placingSignature)
        let data = try Data(contentsOf:file),reopened = try XCTUnwrap(PDFDocument(data:data)),page = try XCTUnwrap(reopened.page(at:0)),cg = try XCTUnwrap(page.thumbnail(of:CGSize(width:200,height:300),for:.mediaBox).cgImage(forProposedRect:nil,context:nil,hints:nil))
        let pixel = SignatureTests().pixel(cg,65,55);XCTAssertTrue(pixel.r<80 && pixel.g<80 && pixel.b<80)
    }
    @MainActor func testReadingDeskStartsClosed() throws { XCTAssertFalse(WorkspaceStore(storage:try root()).showReadingDesk) }
    func testListContinuationNumberingCheckboxAndEmptyListExit() throws {
        XCTAssertEqual(try applied(WritingEdit.newline("9. 第一条",selection:NSRange(location:6,length:0)),to:"9. 第一条"),"9. 第一条\n10. ")
        let task = "  - [x] 事项";XCTAssertEqual(try applied(WritingEdit.newline(task,selection:NSRange(location:task.utf16.count,length:0)),to:task),task+"\n  - [ ] ")
        XCTAssertEqual(try applied(WritingEdit.newline("正文\n- ",selection:NSRange(location:5,length:0)),to:"正文\n- "),"正文\n")
        XCTAssertNil(WritingEdit.newline("普通正文",selection:NSRange(location:4,length:0)))
    }
    func testListIndentDoesNotTouchTheNextUnselectedLine() throws {
        let text = "- 第一项\n- 第二项\n正文",selected = NSRange(location:0,length:6),edit = WritingEdit.indent(text,selection:selected,outdent:false)
        XCTAssertEqual(try applied(edit,to:text),"  - 第一项\n- 第二项\n正文")
        let indented = "  - 一\n    - 二";XCTAssertEqual(try applied(WritingEdit.indent(indented,selection:NSRange(location:0,length:indented.utf16.count),outdent:true),to:indented),"- 一\n  - 二")
        XCTAssertNil(WritingEdit.indent("诗文",selection:NSRange(location:0,length:2),outdent:false))
    }
    func testPasteCleanupIsOptInAndPreservesParagraphs() {
        let text = "第一行\n第二行\n\n诗的第三行";XCTAssertEqual(WritingCleanup().apply(text),text)
        var options = WritingCleanup();options.joinLines = true;XCTAssertEqual(options.apply(text),"第一行第二行\n\n诗的第三行")
        options.dehyphenate = true;options.compactSpaces = true;XCTAssertEqual(options.apply("hist-\nory  of\nChina"),"history of China")
    }
    @MainActor func testFindReplaceAllIsOneUndoAndCompositionIsUntouched() throws {
        let view = ComposingTextView();view.isRichText = false;view.allowsUndo = true;view.string = "中文 History history 中文";let session = WritingSession();session.view = view
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:300),styleMask:[],backing:.buffered,defer:false);window.identifier = NSUserInterfaceItemIdentifier("reading-desk");window.contentView = view;XCTAssertTrue(window.makeFirstResponder(view));XCTAssertTrue(WorkspaceStore.textUndoResponder(in:window) === view)
        session.find("history");XCTAssertEqual(view.selectedRange(),NSRange(location:3,length:7))
        session.replace("history",with:"史学",all:true);XCTAssertEqual(view.string,"中文 史学 史学 中文");view.undoManager?.undo();XCTAssertEqual(view.string,"中文 History history 中文");view.undoManager?.redo();XCTAssertEqual(view.string,"中文 史学 史学 中文")
        view.setSelectedRange(NSRange(location:0,length:0));view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0));let marked = view.string;session.replace("中文",with:"不应替换",all:true);XCTAssertEqual(view.string,marked);XCTAssertTrue(view.hasMarkedText());view.unmarkText()
    }
    @MainActor func testEditorPositionPersistsPerRecordAndClampsAfterShortening() throws {
        let defaults = UserDefaults(suiteName:"Positions045-"+UUID().uuidString)!,positions = WritingPositions(defaults:defaults),view = ComposingTextView();view.string = "第一行\n第二行";view.setSelectedRange(NSRange(location:2,length:1));positions.capture(view,key:"note-a");positions.flush()
        let reopened = WritingPositions(defaults:defaults),other = ComposingTextView();other.string = view.string;reopened.restore(other,key:"note-a");XCTAssertEqual(other.selectedRange(),NSRange(location:2,length:1))
        other.string = "短";reopened.restore(other,key:"note-a");XCTAssertEqual(other.selectedRange(),NSRange(location:1,length:0))
    }
    func testAnalysisFindsChineseHeadingsAndCountsOnlyCommittedText() async {
        let result = await WritingAnalysisWorker.shared.analyze("# 第一章\n正文 中文\n## 第二节")
        XCTAssertEqual(result.headings.map(\.title),["第一章","第二节"]);XCTAssertEqual(result.headings.map(\.level),[1,2]);XCTAssertTrue(result.characters>8)
    }
    @MainActor func testInsertionAtCaretKeepsBothTextHalvesAndFrozenCitation() throws {
        let journal = ReadingJournal(storage:try root()),essay = journal.newEssay(title:"札记");journal.editEssay(essay) { $0.blocks[0].text = "前半后半" };let block = try XCTUnwrap(journal.essay(essay)?.blocks.first),r = record("引文笔记")
        let inserted = journal.insert(r,in:essay,after:block.id,at:NSRange(location:2,length:0)),result = try XCTUnwrap(journal.essay(essay));XCTAssertEqual(result.blocks[0].text,"前半");XCTAssertEqual(result.blocks[1].text,"后半");XCTAssertEqual(result.blocks[1].id,inserted);XCTAssertEqual(result.blocks[1].record,r)
        journal.editRecord(r.id) { $0.note = "后来修改" };XCTAssertEqual(journal.essay(essay)?.blocks[1].record?.note,"引文笔记")
    }
    func testParagraphDragMovesItsCitationAndIdentityTogether() {
        let r = record(),a = ReadingEssay.Block(text:"甲",record:r),b = ReadingEssay.Block(text:"乙"),c = ReadingEssay.Block(text:"丙");var essay = ReadingEssay(blocks:[a,b,c]);essay.move(a.id,before:c.id);XCTAssertEqual(essay.blocks.map(\.id),[b.id,a.id,c.id]);XCTAssertEqual(essay.blocks[1].record,r)
    }
    @MainActor func testSingleParagraphRestoreKeepsCurrentOtherParagraphsAndSource() async throws {
        let journal = ReadingJournal(storage:try root()),r = record();journal.add(r);let backup = try await journal.makeBackup();journal.editRecord(r.id) { $0.note = "改过第一段\n\n保留当前第二段"; $0.quote = "不可覆盖的原文" };let before = journal.state
        try await journal.restoreParagraph(backup.id,item:.record(r.id),index:0,expected:before)
        XCTAssertEqual(journal.record(r.id)?.note,"第一段\n\n保留当前第二段");XCTAssertEqual(journal.record(r.id)?.quote,"不可覆盖的原文");XCTAssertEqual(try ReadingBackupStorage.list(journal.folder).filter{$0.kind == .manual}.count,2)
        do { try await journal.restoreParagraph(backup.id,item:.record(r.id),index:0,expected:before);XCTAssertTrue(false,"stale comparison accepted") } catch {}
    }
    @MainActor func testEssayParagraphRestoreUsesBlockIDAfterReordering() async throws {
        let j = ReadingJournal(storage:try root()),id = j.newEssay(title:"札记");j.editEssay(id) { $0.blocks = [ReadingEssay.Block(text:"甲"),ReadingEssay.Block(text:"乙")] };let old = try XCTUnwrap(j.essay(id)),backup = try await j.makeBackup();j.editEssay(id) { $0.blocks[0].text = "甲已改";$0.move(old.blocks[0].id,delta:1) }
        try await j.restoreParagraph(backup.id,item:.essay(id),index:0,expected:j.state);XCTAssertEqual(j.essay(id)?.blocks.map(\.text),["乙","甲"])
    }
    func testOldJournalAndExportSettingsDecodeWithoutNewFields() throws {
        let bytes = try JSONEncoder().encode(ReadingJournalState(records:[record()]));var json = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]);var records = json["records"] as! [[String:Any]];records[0].removeValue(forKey:"originalQuote");records[0].removeValue(forKey:"originalOCR");json["records"] = records;XCTAssertEqual(try JSONDecoder().decode(ReadingJournalState.self,from:JSONSerialization.data(withJSONObject:json)).records.count,1)
        let old = Data(#"{"fontName":"Songti SC","fontSize":12,"includeQuote":true,"includeNote":true,"includeSources":true}"#.utf8);let options = try JSONDecoder().decode(ReadingExportOptions.self,from:old);XCTAssertTrue(options.valid);XCTAssertNil(options.footnotes)
    }
    func testExportProfilesPersistLayoutAndRejectInvalidOptions() throws {
        let defaults = UserDefaults(suiteName:"Profiles045-"+UUID().uuidString)!,profiles = ReadingExportProfile.presets;try ReadingExportProfile.save(profiles,defaults:defaults);XCTAssertEqual(ReadingExportProfile.load(defaults:defaults).map(\.name),["正文与出处","摘录汇编","读书笔记","研究笔记"])
        var bad = profiles[0];bad.options.margin = 999;XCTAssertThrowsError(try ReadingExportProfile.save([bad],defaults:defaults));XCTAssertEqual(ReadingExportProfile.load(defaults:defaults).count,profiles.count)
    }
    func testMixedExportOrderIncludesNotesAndEssaysInManualOrder() throws {
        let a = record("笔记甲"),b = record("笔记乙"),e = ReadingEssay(title:"札记丙",blocks:[ReadingEssay.Block(text:"论述丙")]);let snapshot = ReadingExportSnapshot(title:"合集",records:[a,b],essays:[e],order:["r:"+b.id.uuidString,"e:"+e.id.uuidString,"r:"+a.id.uuidString]);let md = ReadingRecordExport.markdown(snapshot,imageFolder:"Images");XCTAssertTrue(try XCTUnwrap(md.range(of:"笔记乙")).lowerBound < XCTUnwrap(md.range(of:"论述丙")).lowerBound);XCTAssertTrue(try XCTUnwrap(md.range(of:"论述丙")).lowerBound < XCTUnwrap(md.range(of:"笔记甲")).lowerBound)
    }
    func testWordContainsRealFootnotesAndPreservesLiteralUserMarkers() throws {
        var options = ReadingExportOptions();options.footnotes = true
        let r = record("我的文字 [^literal]"),snapshot = ReadingExportSnapshot(title:"脚注验证",records:[r],options:options),file = try root().appendingPathComponent("脚注.docx");try ReadingRecordExport.word(snapshot,assets:try root(),to:file)
        let xml = try WordExportTests().unzip(["-p",file.path,"word/document.xml"]),notes = try WordExportTests().unzip(["-p",file.path,"word/footnotes.xml"])
        XCTAssertTrue(xml.contains("footnoteReference"));XCTAssertTrue(xml.contains("[^literal]"));XCTAssertTrue(notes.contains("初版"));XCTAssertTrue(notes.contains("PDF 第 9 页"));XCTAssertTrue(notes.contains("印刷页码 五"))
    }
    func testMarkdownOwnFormattingDoesNotReformatLiteralQuote() throws {
        let r = ReadingRecord(kind:.excerpt,quote:"**原文星号**",note:"## 我的标题\n**我的强调**"),snapshot = ReadingExportSnapshot(title:"检查",records:[r]);let rich = try ReadingRecordExport.rich(snapshot,assets:try root())
        XCTAssertTrue(rich.blocks.contains{if case .paragraph(let s,let heading) = $0 { return heading == 2 && s.string == "我的标题" };return false});XCTAssertTrue(rich.blocks.contains{if case .paragraph(let s,_) = $0 { return s.string.contains("**原文星号**") };return false})
    }
    func testBatchPlanGroupsByBookKeepsEssaysSeparateAndDoesNotOverwrite() throws {
        let folder = try root(),a = record("甲"),b = record("乙"),essay = ReadingEssay(title:"札记",blocks:[ReadingEssay.Block(text:"丙")]),snapshot = ReadingExportSnapshot(title:"合集",records:[a,b],essays:[essay]);let plan = try ReadingExportJobs.plan(snapshot,formats:[.word,.markdown],folder:folder)
        XCTAssertEqual(plan.count,4);XCTAssertEqual(plan[0].snapshot.records.count,2);XCTAssertNotNil(plan[2].snapshot.essay);try Data("已有文件".utf8).write(to:plan[0].destination);XCTAssertThrowsError(try ReadingExportJobs.plan(snapshot,formats:[.word],folder:folder))
    }
    func testPackageHasImagesSourcesManifestAndPortableLinks() async throws {
        let folder = try root(),assets = folder.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);let image = try Release029Tests().png();try image.write(to:assets.appendingPathComponent("image.png"))
        let source = folder.appendingPathComponent("原书.pdf");try XCTUnwrap(SignaturePositionTests().document(pages:1).dataRepresentation()).write(to:source)
        var r = record();r.imageAsset = "image.png";r.citations[0].source.path = source.path;let snapshot = ReadingExportSnapshot(title:"便携资料",records:[r]),file = folder.appendingPathComponent("资料.zip")
        try await ReadingPackageWorker.shared.write(snapshot,formats:[.markdown,.word,.pdf],assets:assets,originals:true,to:file,expected:FileBaseline(path:file.path,digest:nil)) {_ in}
        let extracted = folder.appendingPathComponent("解压验证"),process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/ditto");process.arguments = ["-xk",file.path,extracted.path];try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let list = try FileManager.default.subpathsOfDirectory(atPath:extracted.path),md = try String(contentsOf:extracted.appendingPathComponent("阅读资料.md")),manifest = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:extracted.appendingPathComponent("文件校验.json")))
        XCTAssertTrue(list.contains("打开资料包.html"));XCTAssertTrue(list.contains("Images/image.png"));XCTAssertTrue(list.contains(where:{$0.hasPrefix("Sources/")}));XCTAssertTrue(md.contains("Sources/"));XCTAssertTrue(md.contains("#page=9"));XCTAssertNotNil(manifest["阅读资料.pdf"])
        for (name,digest) in manifest { XCTAssertEqual(OCRPageCache.digest(try Data(contentsOf:extracted.appendingPathComponent(name))),digest) }
    }
    func testPackageDefaultsExcludeOriginalsAndProtectsSourceDestination() async throws {
        let folder = try root(),r = record(),snapshot = ReadingExportSnapshot(title:"记录",records:[r]),file = folder.appendingPathComponent("记录.zip")
        try await ReadingPackageWorker.shared.write(snapshot,formats:[.markdown],assets:folder,originals:false,to:file,expected:FileBaseline(path:file.path,digest:nil)) {_ in}
        XCTAssertFalse(try WordExportTests().unzip(["-l",file.path]).contains("Sources/"))
        var protected = r;protected.citations[0].source.path = file.path;let original = try Data(contentsOf:file)
        do { try await ReadingPackageWorker.shared.write(ReadingExportSnapshot(title:"不应覆盖",records:[protected]),formats:[.markdown],assets:folder,originals:false,to:file,expected:try FileBaseline.capture(file)) {_ in};XCTAssertTrue(false,"source overwritten") } catch {};XCTAssertEqual(try Data(contentsOf:file),original)
    }
    @MainActor func testBatchFailureCanRetryOnlyFailedFiles() async throws {
        let folder = try root(),assets = folder.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);var r = record();r.imageAsset = "missing.png";let batch = ReadingExportBatch();batch.start(ReadingExportSnapshot(title:"导出",records:[r]),formats:[.word,.markdown],assets:assets,folder:folder.appendingPathComponent("输出"))
        while batch.busy { try await Task.sleep(nanoseconds:10_000_000) };XCTAssertEqual(batch.jobs.filter{$0.state == .failed}.count,2)
        try Release029Tests().png().write(to:assets.appendingPathComponent("missing.png"));batch.retry();while batch.busy { try await Task.sleep(nanoseconds:10_000_000) };XCTAssertEqual(batch.completed,2)
        let before = try Data(contentsOf:batch.jobs[0].destination);batch.retry();while batch.busy { try await Task.sleep(nanoseconds:10_000_000) };XCTAssertEqual(try Data(contentsOf:batch.jobs[0].destination),before)
    }
    func testBackgroundSearchReturnsAllKindsWithTopicFilter() async throws {
        var r = record();r.tags = ["专题：近代史"];let e = ReadingEssay(title:"近代札记",blocks:[ReadingEssay.Block(text:"正文")],tags:["专题：近代史"]),state = ReadingJournalState(records:[r],essays:[e]);let results = await ReadingSearchWorker.shared.library(state,request:ReadingSearchRequest(revision:1,topic:"近代史"));XCTAssertEqual(results.count,2)
    }
    @MainActor func testCancelledBatchKeepsCompletedResultsAndCanResume() async throws {
        let folder = try root(),batch = ReadingExportBatch();batch.start(ReadingExportSnapshot(title:"笔记",records:[record()]),formats:[.markdown,.pdf],assets:folder,folder:folder.appendingPathComponent("输出"));batch.cancel()
        while batch.busy { try await Task.sleep(nanoseconds:10_000_000) };XCTAssertTrue(batch.jobs.allSatisfy{$0.state == .cancelled || $0.state == .complete});batch.retry();while batch.busy { try await Task.sleep(nanoseconds:10_000_000) };XCTAssertEqual(batch.completed,2)
    }
    @MainActor func testBackgroundStatisticsOnlyPublishesLatestText() async throws {
        let session = WritingSession();session.analyze(String(repeating:"旧文字",count:10000));session.analyze("# 新标题\n新正文")
        try await Task.sleep(nanoseconds:600_000_000);XCTAssertEqual(session.analysis.headings.map(\.title),["新标题"]);XCTAssertEqual(session.analysis.characters,7)
    }

    @MainActor func testOpenPanelLeavesCloudDownloadsToCancellableAppImport() {
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true
        DocumentOpenPanel.configure(panel)
        XCTAssertFalse(panel.canDownloadUbiquitousContents);XCTAssertTrue(panel.canChooseFiles);XCTAssertFalse(panel.canChooseDirectories);XCTAssertTrue(panel.canResolveUbiquitousConflicts)
    }

    @MainActor func testCancelledImportCannotClearNewImportOrInstallOldPages() async throws {
        let folder = try root(),a = folder.appendingPathComponent("旧文件.pdf"),b = folder.appendingPathComponent("新文件.pdf")
        try XCTUnwrap(SignaturePositionTests().document(pages:2).dataRepresentation()).write(to:a);try XCTUnwrap(SignaturePositionTests().document(pages:1).dataRepresentation()).write(to:b)
        let w = Workspace(storage:folder.appendingPathComponent("storage"));w.load([a]);XCTAssertTrue(w.isImporting);w.cancelJob();XCTAssertFalse(w.busy);w.load([b])
        let deadline = Date().addingTimeInterval(10);while w.busy,Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(w.busy);XCTAssertEqual(w.count,1);XCTAssertEqual(w.sourceURL?.path,b.path);XCTAssertNil(w.error)
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertEqual(w.count,1);XCTAssertEqual(w.sourceURL?.path,b.path)
    }
    @MainActor func testClosingLoadingTabImmediatelyCancelsAndDoesNotReopenIt() async throws {
        let folder = try root(),file = folder.appendingPathComponent("稍后读取.pdf");try XCTUnwrap(SignaturePositionTests().document(pages:2).dataRepresentation()).write(to:file)
        let store = WorkspaceStore(storage:folder.appendingPathComponent("storage")),w = store.addWorkspace();w.load([file]);XCTAssertTrue(w.busy);store.close(w.id);XCTAssertFalse(w.busy);XCTAssertFalse(w.isImporting);XCTAssertNil(w.sourceURL)
        try await Task.sleep(nanoseconds:150_000_000);XCTAssertEqual(w.count,0);XCTAssertNil(w.sourceURL);XCTAssertEqual(store.tabs.count,1)
    }

}
