import XCTest
import PDFKit
import AppKit
import Foundation
@testable import KongFolio

@MainActor final class Reading053WorkflowTests: XCTestCase {
    func folder()throws->URL { try Release027Tests().folder() }
    func testProbeReadsValidPDFAndRejectsCorruptFile() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let url=try Release046Tests().pdf(f,pages:5),result=try PDFImportProbe053.inspect(url)
        XCTAssertEqual(result.pages,5);XCTAssertEqual(result.digest,OCRPageCache.digest(try Data(contentsOf:url)))
        let bad=f.appendingPathComponent("damaged.pdf");try Data("%PDF-1.7\n坏文件".utf8).write(to:bad)
        XCTAssertThrowsError(try PDFImportProbe053.inspect(bad,timeout:2))
    }
    func testProbeDeadlineTerminatesNonresponsiveChild() throws {
        let start=Date()
        XCTAssertThrowsError(try PDFImportProbe053.inspect(URL(fileURLWithPath:"/unused"),timeout:0.03,helper:URL(fileURLWithPath:"/usr/bin/yes")))
        XCTAssertTrue(Date().timeIntervalSince(start)<2)
    }
    func testSourceRegionRendersAndRejectsChangedSourceFingerprint() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let url=try Release046Tests().pdf(f),bytes=try Data(contentsOf:url)
        var source=SourceRef(path:url.path,fileName:"生成文献.pdf",page:0,fingerprint:OCRPageCache.digest(bytes),rects:[CGRect(x:10,y:10,width:80,height:100)])
        let png=try PDFImportProbe053.region(source),image=try XCTUnwrap(SignatureImage.loadData(png));XCTAssertTrue(image.width>0);XCTAssertTrue(image.width<=1000)
        source.fingerprint=String(repeating:"0",count:64);XCTAssertThrowsError(try PDFImportProbe053.region(source))
    }
    func testWordExportsActualCommentsAndFootnoteParts() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let origin=ReadingPDFOrigin(annotationID:"generated",type:"批注",contents:"原生批注内容",author:"生成作者",originalCreated:Date(timeIntervalSince1970:1700000000),originalModified:nil)
        let c=ReadingCitation(source:SourceRef(path:"/generated/source.pdf",fileName:"source.pdf",page:3),title:"原书",author:"文献作者")
        var options=ReadingExportOptions();options.nativeWordComments=true;options.footnotes=true
        let r=ReadingRecord(kind:.comment,note:"自己的笔记正文",citations:[c],pdfOrigin:origin),file=f.appendingPathComponent("native.docx")
        try ReadingRecordExport.word(ReadingExportSnapshot(title:"原生注释验证",records:[r],options:options),assets:f,to:file)
        let zip=try ReadingExportAudit.storedZIP(Data(contentsOf:file)),comments=try XCTUnwrap(zip["word/comments.xml"]),document=try XCTUnwrap(zip["word/document.xml"])
        XCTAssertTrue(XMLParser(data:comments).parse());XCTAssertTrue(String(data:comments,encoding:.utf8)!.contains("原生批注内容"));XCTAssertTrue(String(data:comments,encoding:.utf8)!.contains("生成作者"));XCTAssertTrue(String(data:document,encoding:.utf8)!.contains("commentReference"));XCTAssertNotNil(zip["word/footnotes.xml"])
    }
    func testExcelIsValidSpreadsheetPackageWithLiteralCells() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let file=f.appendingPathComponent("目录.xlsx"),item=ReadingLibraryItem.record(ReadingRecord(kind:.note,title:"公式看作文本",note:"=1+2\n第二行"))
        try ReadingCatalog053.xlsx([item],columns:[.title,.note,.created],to:file)
        let zip=try ReadingExportAudit.storedZIP(Data(contentsOf:file)),xml=try XCTUnwrap(zip["xl/worksheets/sheet1.xml"])
        XCTAssertTrue(XMLParser(data:xml).parse());XCTAssertNotNil(zip["xl/workbook.xml"]);XCTAssertTrue(String(data:xml,encoding:.utf8)!.contains("=1+2"));XCTAssertFalse(String(data:xml,encoding:.utf8)!.contains("<f>"))
    }
    func testFirstCitationFullThenShortAndBibliographyDeduplicates() {
        let c=ReadingCitation(source:SourceRef(path:"/generated/book.pdf",fileName:"book.pdf",page:0),title:"原书",author:"作者",edition:"初版")
        var formatter=ReadingCitationFormat053();XCTAssertTrue(formatter.render(c,shorten:true).contains("初版"));XCTAssertFalse(formatter.render(c,shorten:true).contains("初版"))
        let items=[ReadingLibraryItem.record(ReadingRecord(kind:.excerpt,quote:"甲",citations:[c,c]))];XCTAssertEqual(ReadingWorkflow053.bibliography(items).count,1)
    }
    func testUpgradeSnapshotPreservesPreviousStateBeforeFirstNewWrite() async throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let folder=f.appendingPathComponent("ReadingJournal");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let old=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"升级前笔记")]);try JSONEncoder().encode(old).write(to:folder.appendingPathComponent("catalog.json"))
        let journal=ReadingJournal(storage:f);journal.editRecord(old.records[0].id){$0.note="升级后修改"};try await journal.flush()
        let receipt=try JSONDecoder().decode(ReadingUpgradeReceipt053.Receipt.self,from:Data(contentsOf:folder.appendingPathComponent("Upgrade-0.53.0.json")))
        let backup=try ReadingBackupStorage.read(try XCTUnwrap(receipt.backup),folder:folder);XCTAssertEqual(backup.state,old)
    }
    func testPageEditUndoRestoresSourceAndCapturedPage() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let store=WorkspaceStore(storage:f);store.bootstrap();let w=try XCTUnwrap(store.activeWorkspace),file=try Release046Tests().pdf(f,pages:3);w.load([file],prepared:try ImportServices.read([file]));w.readingLocked=false
        let r=ReadingRecord(kind:.excerpt,quote:"摘录正文",citations:[w.readingCitation(page:1)]);store.journal.add(r);w.selectPage(1);w.selectedPages=[1];w.remove()
        XCTAssertEqual(store.journal.record(r.id)?.citations[0].source.invalidPage053,true);w.undo()
        XCTAssertNil(store.journal.record(r.id)?.citations[0].source.invalidPage053);XCTAssertEqual(store.journal.record(r.id)?.citations[0].source.page,1);XCTAssertEqual(store.journal.record(r.id)?.citations[0].tracking?.capturedPage,1)
    }
    func testDocumentIdentitySurvivesRenameAndResolvesOldLink() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let file=try Release046Tests().pdf(f),moved=f.appendingPathComponent("改名文献.pdf"),registry=ReadingDocumentRegistry053(f),digest=OCRPageCache.digest(try Data(contentsOf:file)),before=registry.identity(file.path,digest:digest)
        try FileManager.default.moveItem(at:file,to:moved);let after=registry.identity(moved.path,digest:digest)
        XCTAssertEqual(after.id,before.id);XCTAssertEqual(registry.resolve(file.path),moved.path)
    }
    func testGraphicalMarksOnSamePageAreNotFalseDuplicates() {
        let c=ReadingCitation(source:SourceRef(path:"/generated/book.pdf",fileName:"book.pdf",page:0),title:"原书")
        let a=ReadingRecord(kind:.annotation,citations:[c],pdfOrigin:ReadingPDFOrigin(annotationID:"arrow1",type:"箭头",contents:"",originalCreated:nil,originalModified:nil)),b=ReadingRecord(kind:.annotation,citations:[c],pdfOrigin:ReadingPDFOrigin(annotationID:"arrow2",type:"箭头",contents:"",originalCreated:nil,originalModified:nil))
        XCTAssertTrue(ReadingWorkflow053.duplicateGroups(ReadingJournalState(records:[a,b])).isEmpty)
    }
    func testIdenticalCopiesKeepSeparateDocumentIdentities() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let first=try Release046Tests().pdf(f),copy=f.appendingPathComponent("独立副本.pdf");try FileManager.default.copyItem(at:first,to:copy)
        let registry=ReadingDocumentRegistry053(f),digest=OCRPageCache.digest(try Data(contentsOf:first))
        XCTAssertFalse(registry.identity(first.path,digest:digest).id==registry.identity(copy.path,digest:digest).id)
    }
    func testVisualAnnotationSnapshotRemainsAfterOriginalRemoval() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let store=WorkspaceStore(storage:f);store.bootstrap();let w=try XCTUnwrap(store.activeWorkspace);w.document=SignaturePositionTests().document(pages:1);w.sourceURL=f.appendingPathComponent("generated.pdf")
        let page=try XCTUnwrap(w.document.page(at:0)),a=PDFAnnotation(bounds:CGRect(x:20,y:20,width:80,height:40),forType:.square,withProperties:nil);a.color = .red;page.addAnnotation(a)
        w.captureReadingAnnotationPages([0]);let record=try XCTUnwrap(store.journal.state.records.first),asset=try XCTUnwrap(record.extras?.visualAsset);XCTAssertNotNil(store.journal.pendingImage(asset));page.removeAnnotation(a);w.captureReadingAnnotationPages([0]);XCTAssertEqual(store.journal.record(record.id)?.extras?.visualAsset,asset);XCTAssertNotNil(store.journal.record(record.id)?.pdfOrigin?.missingSince)
    }
    func testColorSemanticsPersistInIndependentDefaults() throws {
        let name="KongFolio053-palette-"+UUID().uuidString,d=try XCTUnwrap(UserDefaults(suiteName:name));defer{d.removePersistentDomain(forName:name)}
        let color=try XCTUnwrap(ReadingColorSemantics053.code(.yellow));ReadingColorSemantics053.set(color,meaning:"重要观点",defaults:d);XCTAssertEqual(ReadingColorSemantics053.meaning(.yellow,defaults:d),"重要观点")
    }
    func testSearchTenThousandRecordsUsesPersistentIndexAndFindsChinese() async throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var values=(0..<10000).map{ReadingRecord(kind:.note,note:"普通笔记第 \($0) 条")};values[7777].note="检索中国近代史料"
        let state=ReadingJournalState(records:values),request=ReadingSearchRequest(revision:1,query:"中国近代",options053:ReadingLibraryOptions053(),indexFolder:f.path)
        let first=await ReadingSearchWorker.shared.library(state,request:request);XCTAssertEqual(first.map(\.id),[.record(values[7777].id)])
        await ReadingSearchIndex053.shared.close();let second=await ReadingSearchWorker.shared.library(state,request:request);XCTAssertEqual(second.map(\.id),first.map(\.id));XCTAssertTrue(FileManager.default.fileExists(atPath:f.appendingPathComponent("Search053.sqlite").path))
    }
    func testAutomaticReadableMirrorWritesLatestCommittedNote() async throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        let parent=f.appendingPathComponent("Readable");try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let journal=ReadingJournal(storage:f),r=ReadingRecord(kind:.note,note:"配置后第一版")
        try ReadingMirrorSettings053.enable(parent,folder:journal.folder);journal.add(r);try await journal.flush();journal.editRecord(r.id){$0.note="最新正文"};try await journal.flush()
        await ReadingMirrorWriter053.shared.drain()
        let file=parent.appendingPathComponent("KongFolio-阅读资料").appendingPathComponent(ReadingLibraryID.record(r.id).filename053)
        XCTAssertTrue(try String(contentsOf:file).contains("最新正文"))
        try ReadingMirrorSettings053.disable(journal.folder)
    }
    func testReadableMirrorThreeRevisionsRetainsPreviousAndStableLinks() throws {
        let f=try folder();defer{try? FileManager.default.removeItem(at:f)}
        var state=ReadingJournalState(records:[ReadingRecord(kind:.note,note:"第一版")])
        _=try ReadingReadable053.write(state,assets:f,to:f);state.records[0].note="第二版";_=try ReadingReadable053.write(state,assets:f,to:f);state.records[0].note="第三版";_=try ReadingReadable053.write(state,assets:f,to:f)
        let name=ReadingLibraryID.record(state.records[0].id).filename053
        XCTAssertTrue(try String(contentsOf:f.appendingPathComponent("KongFolio-阅读资料.previous").appendingPathComponent(name)).contains("第二版"))
    }
    func testDraggedCitationKeepsOriginalTextTimeAndSourceLink() {
        let r=ReadingRecord(kind:.excerpt,quote:"需要保留的原文",citations:[ReadingCitation(source:SourceRef(path:"/generated/book.pdf",fileName:"book.pdf",page:8),title:"原书",author:"作者")],created:Date(timeIntervalSince1970:1700000000))
        let text=ReadingDrag053.text(.record(r),assets:URL(fileURLWithPath:"/generated/Assets"))
        for piece in ["需要保留的原文","作者","原书","PDF 第 9 页","记录时间","kongfolio://source","kongfolio://record"] { XCTAssertTrue(text.contains(piece),piece) }
    }
}
