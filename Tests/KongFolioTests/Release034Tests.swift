import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release034Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func data() throws -> Data { try Release033Tests().tablePDF() }
    func draft(_ bytes: Data) -> TableDraftRecord { var value=Release033Tests().record(data:bytes);value.rows=[["A","B"],["one","two"]];return value }
    func xml(_ url: URL, _ part: String = "word/document.xml") throws -> String { try WordExportTests().unzip(["-p",url.path,part]) }
    @MainActor func wait(_ queue: DocumentTaskQueue) async throws { try await Release033Tests().wait(queue) }
    @MainActor func workspace(_ root: URL, _ bytes: Data) -> Workspace { let w=Workspace(storage:root);w.bootstrap();w.document=PDFDocument(data:bytes)!;w.cachedPDF=bytes;return w }
    func testMergeCellsPreservesTextAndSplitRetainsCombinedContent() throws {
        var value=draft(try data());let span=TableCellSpan(row:0,column:0,rows:2,columns:2)
        try TableStructure.merge(span,draft:&value);XCTAssertEqual(value.rows,[["A\nB\none\ntwo",""],["",""]]);XCTAssertEqual(value.spans,[span]);try value.validate()
        TableStructure.split(row:1,column:1,draft:&value);XCTAssertEqual(value.spans,[]);XCTAssertEqual(value.rows[0][0],"A\nB\none\ntwo")
    }
    func testPartialMergedRegionCannotBeMergedAgain() throws {
        var value=draft(try data());try TableStructure.merge(TableCellSpan(row:0,column:0,rows:1,columns:2),draft:&value)
        XCTAssertThrowsError(try TableStructure.merge(TableCellSpan(row:0,column:1,rows:2,columns:1),draft:&value));XCTAssertEqual(value.rows[0][0],"A\nB")
    }
    func testSpanValidationRejectsOverlapAndOutsideOrOverflow() throws {
        let rows=[["a",""],["",""]],span=TableCellSpan(row:0,column:0,rows:2,columns:2)
        XCTAssertThrowsError(try TableStructure.validate(rows:rows,spans:[span,span]))
        XCTAssertThrowsError(try TableStructure.validate(rows:rows,spans:[TableCellSpan(row:Int.max,column:0,rows:2,columns:1)]))
        XCTAssertThrowsError(try TableStructure.validate(rows:rows,spans:[TableCellSpan(row:0,column:0,rows:0,columns:2)]))
    }
    func testStructuralChangesAdjustMergedAnchorsAndKeepTheirText() throws {
        var value=draft(try data());try TableStructure.merge(TableCellSpan(row:0,column:0,rows:2,columns:2),draft:&value)
        try TableStructure.structure(.insertRow(1),draft:&value);XCTAssertEqual(value.spans?.first?.rows,3)
        try TableStructure.structure(.deleteRow(0),draft:&value);XCTAssertEqual(value.rows[0][0],"A\nB\none\ntwo");XCTAssertEqual(value.spans?.first?.rows,2)
        try TableStructure.structure(.deleteColumn(0),draft:&value);XCTAssertEqual(value.rows[0][0],"A\nB\none\ntwo");try value.validate()
    }
    func testTSVPasteHandlesQuotedCellsNewlinesAndEscapedQuotes() throws {
        XCTAssertEqual(try TableStructure.parseTSV("a\t\"line1\nline2\"\r\n\"a\"\"b\"\tc\n"),[["a","line1\nline2"],["a\"b","c"]])
        XCTAssertThrowsError(try TableStructure.parseTSV("\"not closed"))
    }
    func testPasteExpandsGridAndRejectsMergedOrOversizedTargets() throws {
        var value=draft(try data());try TableStructure.paste("x\ty\nz\tw",row:1,column:1,draft:&value)
        XCTAssertEqual(value.rows,[["A","B",""],["one","x","y"],["","z","w"]])
        try TableStructure.merge(TableCellSpan(row:0,column:0,rows:1,columns:2),draft:&value)
        XCTAssertThrowsError(try TableStructure.paste("replace",row:0,column:0,draft:&value));XCTAssertThrowsError(try TableStructure.paste("x",row:2000,column:0,draft:&value))
    }
    @MainActor func testMergePasteUndoAndReopenKeepSpansAndRows() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),record=draft(bytes),model=TableEditorModel(storage:root)
        model.open(data:bytes,page:0,identity:"test",sourcePath:nil,title:"test",saved:record);try await Release033Tests().wait(model)
        model.edit { try TableStructure.merge(TableCellSpan(row:0,column:0,rows:1,columns:2),draft:&$0) };XCTAssertEqual(model.draft?.spans?.count,1)
        model.undo();XCTAssertEqual(model.draft?.rows,record.rows);model.redo()
        let saved=try TableDraftStore.read(TableDraftStore.url(record.id,storage:root));XCTAssertEqual(saved.spans?.count,1);XCTAssertEqual(saved.rows[0][0],"A\nB")
    }
    func testExcelUsesRealMergeRangesAndSafeInlineStrings() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };var value=draft(try data());value.rows[0][0]="=1+2 & 中文"
        try TableStructure.merge(TableCellSpan(row:0,column:0,rows:1,columns:2),draft:&value)
        let file=root.appendingPathComponent("table.xlsx");try TableStructure.writeExcel(rows:value.rows,spans:value.spans!,to:file)
        let sheet=try xml(file,"xl/worksheets/sheet1.xml")
        XCTAssertTrue(sheet.contains("mergeCell ref=\"A1:B1\""));XCTAssertTrue(sheet.contains("t=\"inlineStr\""));XCTAssertTrue(sheet.contains("=1+2 &amp; 中文&#10;B"));XCTAssertFalse(sheet.contains("<f>"));XCTAssertTrue(try WordExportTests().unzip(["-t",file.path]).contains("No errors detected"))
    }
    func testWordTableSpansUseGridSpanAndVerticalMerge() throws {
        var value=draft(try data());try TableStructure.merge(TableCellSpan(row:0,column:0,rows:2,columns:2),draft:&value)
        let xml=WordTables.xml(value.rows,spans:value.spans!)
        XCTAssertTrue(xml.contains("gridSpan w:val=\"2\""));XCTAssertTrue(xml.contains("vMerge w:val=\"restart\""));XCTAssertTrue(xml.contains("<w:vMerge/>"));XCTAssertEqual(xml.components(separatedBy:"<w:tc>").count-1,2)
    }
    @MainActor func testWordMixedDraftEditsBodyAndCellPersistsAndExportsOnce() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),w=workspace(root,bytes);var record=draft(bytes);record.includeInWord=true;w.tableDrafts=[record];w.wordOptions.content = .textOnly
        var options=try w.wordOptionsWithTables();let base=try WordCleanup.inspect(w.document,pages:[0,1],options:options,regions:[:],sourceDigest:OCRPageCache.digest(bytes)).pages[0].blocks!
        let paragraph=base.firstIndex { if case .paragraph(let p)=$0 { return p.text.contains("Before") };return false }!,table=base.firstIndex { if case .table=$0 { return true };return false }!
        let body=try WordMixedDraft.replacing(base,block:paragraph,row:nil,column:nil,text:"Edited before table")
        let changed=try WordMixedDraft.replacing(body,block:table,row:1,column:0,text:"edited cell")
        try w.setWordBlocks(changed,base:base,page:0)
        let archived=try JSONDecoder().decode(WordDraftArchive.self,from:Data(contentsOf:w.wordDraftURL));XCTAssertTrue(archived.options.draftText.contains("edited cell"));XCTAssertTrue(archived.options.draftText.contains("Edited before table"))
        let restored=workspace(root,bytes);restored.tableDrafts=w.tableDrafts;restored.restoreWordDraft(archived,sourceDigest:OCRPageCache.digest(bytes));try restored.validateWordDraft()
        options=try restored.wordOptionsWithTables();let file=root.appendingPathComponent("mixed.docx");_ = try WordExport.write(restored.document,pages:[0,1],outline:[],options:options,to:file,sourceDigest:OCRPageCache.digest(bytes))
        let output=try xml(file);XCTAssertTrue(output.contains("Edited before table"));XCTAssertTrue(output.contains("edited cell"));XCTAssertFalse(output.contains(">one<"));XCTAssertEqual(output.components(separatedBy:"<w:tbl>").count-1,1)
    }
    @MainActor func testMixedDraftRefusesChangedTableAndKeepsTextForRecovery() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),w=workspace(root,bytes);var record=draft(bytes);record.includeInWord=true;w.tableDrafts=[record]
        let options=try w.wordOptionsWithTables(),base=try WordCleanup.inspect(w.document,pages:[0],options:options,regions:[:],sourceDigest:OCRPageCache.digest(bytes)).pages[0].blocks!
        try w.setWordBlocks(base,base:base,page:0);w.tableDrafts[0].rows[1][0]="new table"
        XCTAssertThrowsError(try WordCleanup.inspect(w.document,pages:[0],options:w.wordOptionsWithTables(),regions:[:],sourceDigest:OCRPageCache.digest(bytes)))
        XCTAssertTrue(w.wordDraftText.contains("one"));w.clearWordDraft(page:0);XCTAssertFalse(w.wordOptions.hasDraft)
    }
    func testMixedDraftRejectsStructuralReplacementAndCoveredCellEditing() throws {
        let span=TableCellSpan(row:0,column:0,rows:1,columns:2),base:[WordPreparedBlock]=[.paragraph(WordPreparedParagraph(text:"before")),.spanningTable(rows:[["a",""]],spans:[span])]
        XCTAssertThrowsError(try WordMixedDraft.validate(Array(base.reversed()),against:base));XCTAssertThrowsError(try WordMixedDraft.replacing(base,block:1,row:0,column:1,text:"hidden"))
        XCTAssertEqual(try JSONDecoder().decode([WordPreparedBlock].self,from:JSONEncoder().encode(base)),base)
    }
    func testWordCacheReusesCompletedPagesAndInvalidatesChangedOptions() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),document=PDFDocument(data:bytes)!;var options=WordExportOptions();options.content = .textOnly
        let file=root.appendingPathComponent("first.docx");_ = try WordExport.write(document,pages:[0,1],outline:[],options:options,to:file,sourceDigest:OCRPageCache.digest(bytes),cache:root)
        let checkpoint=root.appendingPathComponent("word-0.json"),saved=try Data(contentsOf:checkpoint),time=try checkpoint.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        _ = try WordExport.write(document,pages:[0,1],outline:[],options:options,to:root.appendingPathComponent("again.docx"),sourceDigest:OCRPageCache.digest(bytes),cache:root)
        XCTAssertEqual(try Data(contentsOf:checkpoint),saved);XCTAssertEqual(try checkpoint.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,time)
        options.pageMarks=false;_ = try WordExport.write(document,pages:[0,1],outline:[],options:options,to:root.appendingPathComponent("changed.docx"),sourceDigest:OCRPageCache.digest(bytes),cache:root)
        XCTAssertFalse(try Data(contentsOf:checkpoint)==saved)
    }
    func testCrossPageCacheKeepsIdenticalResultWithoutRewritingCompletedFragment() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),record=draft(bytes)
        let a=try TableMerge.extract(data:bytes,current:record,pages:[0,1],removeHeaders:true,languages:["en-US"],cache:root)
        let checkpoint=root.appendingPathComponent("table-1.json"),time=try checkpoint.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        let b=try TableMerge.extract(data:bytes,current:record,pages:[0,1],removeHeaders:true,languages:["en-US"],cache:root)
        XCTAssertEqual(a.rows,b.rows);XCTAssertEqual(try checkpoint.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,time)
    }
    @MainActor func testPersistentTaskPausesRestartsAndResumesCompletedPageCheckpoints() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let pdf=PDFDocument(data:try data())!
        for _ in 0..<6 { pdf.insert(pdf.page(at:0)!.copy() as! PDFPage,at:pdf.pageCount) }
        let bytes=pdf.dataRepresentation()!,file=root.appendingPathComponent("flat.pdf"),queue=DocumentTaskQueue(storage:root)
        let id=try queue.startPersistent("flatten",source:bytes,spec:PersistentDocumentTask(kind:.flatten,destination:file,expected:try FileBaseline.capture(file)))
        let deadline=Date().addingTimeInterval(10)
        while (queue.items.first?.progress ?? 0)==0,queue.running,Date()<deadline { try await Task.sleep(nanoseconds:2_000_000) }
        queue.pause(id);try await wait(queue);XCTAssertEqual(queue.items.first?.state,.paused)
        let checkpointFolder=try queue.taskFolder(id),checkpoints=try FileManager.default.contentsOfDirectory(at:checkpointFolder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("flat-")};XCTAssertFalse(checkpoints.isEmpty)
        let resumed=DocumentTaskQueue(storage:root);XCTAssertTrue(resumed.canResume(id));try resumed.resume(id);try await wait(resumed)
        XCTAssertEqual(resumed.items.first?.state,.finished);XCTAssertEqual(PDFDocument(url:file)?.pageCount,pdf.pageCount)
        let again=DocumentTaskQueue(storage:root);XCTAssertEqual(again.items.first?.state,.finished);XCTAssertFalse(again.canResume(id));XCTAssertFalse(FileManager.default.fileExists(atPath:checkpointFolder.path))
    }
    @MainActor func testResumeChecksExternalOriginalAndPreservesDestination() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),original=root.appendingPathComponent("original.pdf"),target=root.appendingPathComponent("out.pdf");try bytes.write(to:original);try Data("existing".utf8).write(to:target)
        var spec=PersistentDocumentTask(kind:.flatten,destination:target,expected:try FileBaseline.capture(target),sourceBaseline:try FileBaseline.capture(original));spec.sourceDigest=OCRPageCache.digest(bytes)
        try Data("external edit".utf8).write(to:original)
        XCTAssertThrowsError(try spec.run(source:bytes,folder:root,progress:{_ in}));XCTAssertEqual(try Data(contentsOf:target),Data("existing".utf8))
    }
    @MainActor func testRetryFailedTasksDoesNotRestartCompletedTasks() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),parent=root.appendingPathComponent("missing"),target=parent.appendingPathComponent("table.csv"),queue=DocumentTaskQueue(storage:root)
        var spec=PersistentDocumentTask(kind:.table,destination:target,expected:try FileBaseline.capture(target));spec.draft=draft(bytes);spec.suffix="csv"
        let id=try queue.startPersistent("retry",source:bytes,spec:spec);try await wait(queue);XCTAssertEqual(queue.items.first?.state,.failed)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true);queue.retryFailed();try await wait(queue);XCTAssertEqual(queue.items.first?.state,.finished);XCTAssertFalse(queue.canResume(id));XCTAssertTrue(try String(contentsOf:target).contains("one"))
    }
    @MainActor func testBrokenTaskIndexRemainsBackedUpWhenNewTaskStarts() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let taskFolder=root.appendingPathComponent("DocumentTasks");try FileManager.default.createDirectory(at:taskFolder,withIntermediateDirectories:true);let broken=Data("unreadable-index".utf8);try broken.write(to:taskFolder.appendingPathComponent("index.json"))
        let queue=DocumentTaskQueue(storage:root);XCTAssertFalse(queue.persistenceMessage.isEmpty);let bytes=try data();var spec=PersistentDocumentTask(kind:.table,destination:root.appendingPathComponent("a.csv"),expected:try FileBaseline.capture(root.appendingPathComponent("a.csv")));spec.draft=draft(bytes);spec.suffix="csv"
        try queue.startPersistent("new",source:bytes,spec:spec);try await wait(queue)
        let backup=try FileManager.default.contentsOfDirectory(at:taskFolder,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("unreadable-")};XCTAssertNotNil(backup);XCTAssertEqual(try Data(contentsOf:backup!),broken)
    }
    func testTemplateGeometryClampsMoveAndResizeInsidePage() {
        let rect=CGRect(x:0.2,y:0.3,width:0.4,height:0.1),moved=FormTemplateTools.moved(rect,dx:2,dy:-2),resized=FormTemplateTools.resized(rect,dw:2,dh:-2)
        XCTAssertEqual(moved.maxX,1,accuracy:0.0001);XCTAssertEqual(moved.minY,0,accuracy:0.0001);XCTAssertEqual(resized.maxX,1,accuracy:0.0001);XCTAssertEqual(resized.height,0.01,accuracy:0.0001)
    }
    func testTemplateAlignmentIsAtomicAndRejectsOutsidePageResult() throws {
        var template=Release033Tests().template(DocumentServicesTests().fixture().page(at:0)!),ids=Set<UUID>();ids=Set(template.fields.map(\.id))
        try FormTemplateTools.align(&template,ids:ids,mode:.left);XCTAssertEqual(template.fields[0].rect.minX,template.fields[1].rect.minX)
        template.fields[1].rect.origin.x=0.9;let before=template
        XCTAssertThrowsError(try FormTemplateTools.align(&template,ids:ids,mode:.width));XCTAssertEqual(template,before)
    }
    func testDetectedCandidateFilteringClassifiesAndDeduplicates() {
        let a=CGRect(x:0.1,y:0.2,width:0.2,height:0.04),b=CGRect(x:0.4,y:0.2,width:0.03,height:0.03)
        let values=FormTemplateTools.candidates(rectangles:[a,a,b,CGRect(x:0,y:0,width:1,height:1)])
        XCTAssertEqual(values.count,2);XCTAssertTrue(values.contains{$0.kind == .text});XCTAssertTrue(values.contains{$0.kind == .check})
    }
    func testLocalFormDetectionFindsDrawnCheckboxAndTextRectangle() throws {
        let image=NSImage(size:CGSize(width:1000,height:1000));image.lockFocus();NSColor.white.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:1000,height:1000)).fill();NSColor.black.setStroke()
        for rect in [CGRect(x:100,y:600,width:300,height:50),CGRect(x:600,y:600,width:35,height:35)] { let path=NSBezierPath(rect:rect);path.lineWidth=3;path.stroke() };image.unlockFocus()
        var rect=CGRect(origin:.zero,size:image.size);let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!,values=try FormTemplateTools.detect(cg)
        XCTAssertTrue(values.contains{$0.kind == .text});XCTAssertTrue(values.contains{$0.kind == .check})
    }
    @MainActor func testBatchTemplateCreatesIndependentFieldsAndSingleUndo() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let w=workspace(root,try data()),template=Release033Tests().template(w.document.page(at:0)!)
        try w.applyFormTemplate(template,pages:[0,1],from:w.revision);let fields=PDFForms.fields(w.document);XCTAssertEqual(fields.count,4);XCTAssertEqual(Set(fields.map(\.name)).count,4)
        try w.applyFormValues([fields[0].id:"first",fields[2].id:"second"],from:w.revision);let saved=PDFForms.fields(PDFDocument(data:try w.pdfData())!);XCTAssertEqual(saved[0].value,"first");XCTAssertEqual(saved[2].value,"second")
        w.undo();w.undo();XCTAssertTrue(PDFForms.fields(w.document).isEmpty)
    }
    @MainActor func testBatchTemplateValidationRejectsAllBeforeAnyMutation() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let w=workspace(root,try data()),template=Release033Tests().template(w.document.page(at:0)!)
        w.document.page(at:1)!.setBounds(CGRect(x:0,y:0,width:600,height:300),for:.cropBox)
        XCTAssertThrowsError(try w.applyFormTemplate(template,pages:[0,1],from:w.revision));XCTAssertTrue(PDFForms.fields(w.document).isEmpty)
        XCTAssertThrowsError(try w.applyFormTemplate(template,pages:[0,0],from:w.revision));XCTAssertTrue(PDFForms.fields(w.document).isEmpty)
    }
    func testPreflightFindsMissingLocalAndRemoteImagesWithExactRanges() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let text="正文\n![missing](missing.png)\n![web](https://example.com/a.png)"
        let issues=ExportPreflight.text(text,format:.markdown,baseURL:root,options:TextLayoutOptions());XCTAssertEqual(issues.count,2);XCTAssertTrue(issues.allSatisfy{$0.severity == .blocking && $0.target == .text && $0.range != nil})
        XCTAssertEqual((text as NSString).substring(with:issues[0].range!),"missing.png")
    }
    func testPreflightIgnoresMarkdownImagesInsideFencedCode() {
        let text="```md\n![sample](not-a-real-file.png)\n```"
        XCTAssertTrue(ExportPreflight.text(text,format:.markdown,baseURL:nil,options:TextLayoutOptions()).isEmpty)
    }
    func testPreflightBlocksEmptyTextAndInvalidPageRanges() throws {
        XCTAssertTrue(ExportPreflight.text("  ",format:.plain,baseURL:nil,options:TextLayoutOptions()).contains{$0.severity == .blocking})
        let bytes=try data();XCTAssertTrue(ExportPreflight.pdf(bytes,pages:[0,99],kind:.pdf).contains{$0.severity == .blocking});XCTAssertTrue(ExportPreflight.pdf(bytes,pages:[0,0],kind:.pdf).contains{$0.severity == .blocking})
    }
    func testPreflightLocatesPartialCrossPageAndStaleTables() throws {
        let bytes=try data();var table=Release033Tests().insertion(data:bytes),options=WordExportOptions();options.tables=[table]
        let partial=ExportPreflight.pdf(bytes,pages:[0],kind:.word,options:options);XCTAssertTrue(partial.contains{$0.target == .table && $0.severity == .blocking && $0.page == 0})
        table.sourceDigest=String(repeating:"0",count:64);options.tables=[table];XCTAssertTrue(ExportPreflight.pdf(bytes,pages:[0,1],kind:.word,options:options).contains{$0.message.contains("原文已变化")})
    }
    func testPDFPreflightIgnoresWordOnlyTableConflicts() throws {
        let bytes=try data();var options=WordExportOptions();options.tables=[Release033Tests().insertion(data:bytes)];options.editedText=[0:"manual"]
        XCTAssertTrue(ExportPreflight.pdf(bytes,pages:[0],kind:.pdf,options:options).isEmpty)
        XCTAssertTrue(ExportPreflight.pdf(bytes,pages:[0,1],kind:.word,options:options).contains{$0.target == .word})
    }
    func testTablePreflightWarnsForStaleStandaloneDraftAndBlocksNewGuides() throws {
        var record=draft(try data());XCTAssertEqual(ExportPreflight.table(record,currentDigest:"changed").first?.severity,.warning)
        record.needsRegeneration=true;XCTAssertEqual(ExportPreflight.table(record,currentDigest:record.sourceDigest).first?.severity,.blocking)
    }
    @MainActor func testMixedDraftRecoveryCatalogIncludesParagraphAndTableEdits() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),w=workspace(root,bytes),base:[WordPreparedBlock]=[.paragraph(WordPreparedParagraph(text:"saved paragraph")),.table([["saved cell"]])]
        try w.setWordBlocks(base,base:base,page:0)
        let item=try RecoveryCatalog.list(storage:root).first{$0.kind == .word}!,preview=try RecoveryCatalog.preview(item)
        XCTAssertTrue(preview.text.contains("saved paragraph"));XCTAssertTrue(preview.text.contains("saved cell"))
    }
    @MainActor func testPreflightSignatureTracksTablesAndMixedEditsAndOptions() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),w=workspace(root,bytes);var record=draft(bytes);record.includeInWord=true;w.tableDrafts=[record]
        let initial=try w.exportReviewSignature(.word);w.tableDrafts[0].rows[1][0]="changed";XCTAssertFalse(initial == (try w.exportReviewSignature(.word)))
        let pdf=try w.exportReviewSignature(.pdf);w.tableDrafts[0].needsRegeneration=true;XCTAssertEqual(pdf,try w.exportReviewSignature(.pdf))
    }
    @MainActor func testPausedPersistentHistorySurvivesManyShortTasks() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let queue=DocumentTaskQueue(storage:root),bytes=try data(),target=root.appendingPathComponent("paused.pdf")
        let id=try queue.startPersistent("paused",source:bytes,spec:PersistentDocumentTask(kind:.flatten,destination:target,expected:try FileBaseline.capture(target)))
        queue.pause(id);try await wait(queue);XCTAssertEqual(queue.items.first?.state,.paused)
        for _ in 0..<22 { try queue.start("short") { _ in DocumentTaskResult(message:"done") };try await wait(queue) }
        XCTAssertTrue(queue.canResume(id));XCTAssertTrue(DocumentTaskQueue(storage:root).canResume(id))
    }
    func testPersistentExportCannotReplaceItsOriginalEvenWithMatchingBaseline() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let bytes=try data(),file=root.appendingPathComponent("original.pdf");try bytes.write(to:file)
        var spec=PersistentDocumentTask(kind:.word,destination:file,expected:try FileBaseline.capture(file),sourceBaseline:try FileBaseline.capture(file));spec.sourceDigest=OCRPageCache.digest(bytes);spec.pages=[0];spec.word=WordExportOptions()
        XCTAssertThrowsError(try spec.run(source:bytes,folder:root,progress:{_ in}));XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testExcelRejectsOversizedCellBeforeCreatingOutput() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("large.xlsx")
        XCTAssertThrowsError(try TableStructure.writeExcel(rows:[[String(repeating:"x",count:32768)]],spans:[],to:file));XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testStructuredWordAndExcelRetainTwoDimensionalMerges() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };var record=draft(try data());try TableStructure.merge(TableCellSpan(row:0,column:0,rows:2,columns:2),draft:&record)
        let word=root.appendingPathComponent("merged.docx"),excel=root.appendingPathComponent("merged.xlsx");try StructuredTableWord.write(record,to:word);try TableStructure.writeExcel(rows:record.rows,spans:record.spans!,to:excel)
        XCTAssertTrue(try xml(word).contains("vMerge w:val=\"restart\""));XCTAssertTrue(try xml(excel,"xl/worksheets/sheet1.xml").contains("A1:B2"));XCTAssertTrue(try xml(excel,"xl/styles.xml").contains("wrapText=\"1\""))
    }

    @MainActor func testIssueLocationSelectsExactPageAndDraftWithoutOpeningCompetingPanels() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let store=WorkspaceStore(storage:root);store.bootstrap();let w=store.activeWorkspace!;w.document=PDFDocument(data:try data())!;let id=UUID()
        store.locateExportIssue(ExportReviewIssue(severity:.blocking,message:"table",target:.table,page:1,tableID:id),workspace:w)
        XCTAssertEqual(w.selection,1);XCTAssertEqual(w.pendingTableDraftID,id);XCTAssertTrue(w.showTableExtraction);XCTAssertFalse(w.showWordExport)
        store.locateExportIssue(ExportReviewIssue(severity:.blocking,message:"word",target:.word,page:0),workspace:w)
        XCTAssertEqual(w.selection,0);XCTAssertEqual(w.pendingWordPreviewPage,0);XCTAssertFalse(w.showTableExtraction);XCTAssertTrue(w.showWordExport)
    }

    @MainActor func testRetryFailedQueuesAllFailuresAndRestoresWaitingAsPaused() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }
        let queue=DocumentTaskQueue(storage:root),bytes=try data(),parent=root.appendingPathComponent("missing")
        for index in 0..<3 {
            let target=parent.appendingPathComponent("table-\(index).csv")
            var spec=PersistentDocumentTask(kind:.table,destination:target,expected:try FileBaseline.capture(target));spec.draft=draft(bytes);spec.suffix="csv"
            try queue.startPersistent("retry",source:bytes,spec:spec);try await wait(queue)
        }
        XCTAssertEqual(queue.items.filter{$0.state == .failed}.count,3)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        queue.retryFailed();XCTAssertEqual(queue.activeCount,2)
        XCTAssertEqual(queue.items.filter{$0.state == .queued}.count,1)
        let restored=DocumentTaskQueue(storage:root);XCTAssertEqual(restored.items.filter{$0.state == .paused}.count,3)
        try await wait(queue);XCTAssertEqual(queue.items.filter{$0.state == .finished}.count,3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil).count,3)
    }

}
