import XCTest
import AppKit
import CoreText
import PDFKit
@testable import KongFolio

final class Release033Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func pdf(_ text: String = "source history") throws -> Data { try Release027Tests().pdf([text]) }
    func record(data: Data, path: String? = nil, page: Int = 0) -> TableDraftRecord {
        var value = TableDraftRecord(identity: path.map { URL(fileURLWithPath:$0).standardizedFileURL.path } ?? "test", sourcePath:path, sourceTitle:"测试表格.pdf", sourceDigest:OCRPageCache.digest(data),page:page)
        value.grid = TableGrid(region:CGRect(x:0.1,y:0.25,width:0.8,height:0.5),x:[0.1,0.5,0.9],y:[0.25,0.5,0.75]); value.rows = [["Column A","Column B"],["one","two"]]; return value
    }
    @MainActor func wait(_ model: TableEditorModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.working, Date() < deadline { try await Task.sleep(nanoseconds:2_000_000) }; XCTAssertFalse(model.working)
    }
    @MainActor func wait(_ queue: DocumentTaskQueue) async throws {
        let deadline = Date().addingTimeInterval(10)
        while queue.running, Date() < deadline { try await Task.sleep(nanoseconds:2_000_000) }; XCTAssertFalse(queue.running)
    }
    @MainActor func testDeferredTabsDoNotReadOriginalUntilSelectedAndRecoveryUsesSavedBaseline() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("deferred.pdf"), data = try pdf()
        try data.write(to: file)
        let workspace = Workspace(storage: root); workspace.bootstrap(); workspace.needsLoad = true; workspace.sourceURL = file
        XCTAssertNil(workspace.fileBaseline); XCTAssertEqual(workspace.count, 0)
        workspace.ensureLoaded()
        let deadline = Date().addingTimeInterval(5)
        while workspace.busy, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertGreaterThan(workspace.count, 0); XCTAssertEqual(workspace.fileBaseline?.digest, OCRPageCache.digest(data))
        let archive = try workspace.snapshot(); try pdf("externally changed").write(to: file)
        let recovered = Workspace(storage: root); try recovered.restore(archive)
        XCTAssertEqual(recovered.fileBaseline, archive.fileBaseline); XCTAssertThrowsError(try recovered.fileBaseline!.verify(file))
    }
    func testRepeatedCrossPageMergeDoesNotDuplicateRowsAndExtensionKeepsEdits() throws {
        let document = PDFDocument(data: try tablePDF())!
        document.insert(document.page(at: 1)!.copy() as! PDFPage, at: 2)
        let data = document.dataRepresentation()!
        var draft = record(data: data)
        draft.rows = [["A", "B"], ["edited", "two"]]
        let first = try TableMerge.extract(data: data, current: draft, pages: [0, 1], removeHeaders: true, languages: ["en-US"])
        draft.rows = first.rows; draft.sourceRegions = first.regions
        let repeatMerge = try TableMerge.extract(data: data, current: draft, pages: [0, 1], removeHeaders: true, languages: ["en-US"])
        XCTAssertEqual(repeatMerge.rows, first.rows); XCTAssertEqual(repeatMerge.regions, first.regions)
        let extended = try TableMerge.extract(data: data, current: draft, pages: [0, 1, 2], removeHeaders: true, languages: ["en-US"])
        XCTAssertEqual(extended.regions.count, 3); XCTAssertEqual(extended.rows.count, first.rows.count + 1)
        XCTAssertEqual(extended.rows[1][0], "edited")
        draft.rows = extended.rows; draft.sourceRegions = extended.regions
        XCTAssertThrowsError(try TableMerge.extract(data: data, current: draft, pages: [0, 1], removeHeaders: true, languages: ["en-US"]))
    }
    @MainActor func testTaskHistoryLimitKeepsLongRunningTasksAndConcurrencyLimit() async throws {
        let queue = DocumentTaskQueue()
        let long = try queue.start("long") { _ in
            while true { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) }
        }
        defer { queue.cancelAll() }
        for _ in 0..<22 {
            let quick = try queue.start("quick") { _ in DocumentTaskResult(message: "done") }
            let deadline = Date().addingTimeInterval(5)
            while queue.items.first(where: { $0.id == quick })?.active == true, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
            XCTAssertEqual(queue.items.first(where: { $0.id == quick })?.state, .finished)
        }
        XCTAssertEqual(queue.items.count, 20); XCTAssertTrue(queue.items.contains { $0.id == long && $0.active }); XCTAssertEqual(queue.activeCount, 1)
        try queue.start("second") { _ in while true { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) } }
        XCTAssertThrowsError(try queue.start("third") { _ in DocumentTaskResult(message: "unexpected") })
        queue.cancelAll(); try await wait(queue)
    }
    func testGridDragClampsWithoutCrossingAndRejectsInvalidGeometry() throws {
        var grid = TableGrid(x:[0,0.4,0.8,1],y:[0,0.5,1]); try grid.move(vertical:true,index:1,value:2)
        XCTAssertEqual(grid.x[1],0.798,accuracy:0.0001); try grid.move(vertical:false,index:1,value:-1); XCTAssertEqual(grid.y[1],0.002,accuracy:0.0001)
        XCTAssertThrowsError(try grid.move(vertical:true,index:0,value:0.1)); XCTAssertThrowsError(try grid.move(vertical:true,index:1,value:.nan))
        grid.region = CGRect(x:0,y:0,width:2,height:1); XCTAssertThrowsError(try grid.validate())
    }
    func testStructuralCellEditsPreserveNeighboursAndMinimumSize() throws {
        let rows = [["a","b"],["c","d"]]
        XCTAssertEqual(try TableCellEdit.insertRow(1).applying(to:rows),[["a","b"],["",""],["c","d"]])
        XCTAssertEqual(try TableCellEdit.insertColumn(1).applying(to:rows),[["a","","b"],["c","","d"]])
        XCTAssertEqual(try TableCellEdit.deleteColumn(0).applying(to:rows),[["b"],["d"]])
        XCTAssertThrowsError(try TableCellEdit.deleteRow(0).applying(to:[["a"]])); XCTAssertThrowsError(try TableCellEdit.deleteColumn(0).applying(to:[["a"]]))
        XCTAssertThrowsError(try TableCellEdit.insertRow(0).applying(to:Array(repeating:Array(repeating:"",count:100),count:20)))
    }
    @MainActor func testTableCellEditingUndoRedoAndReopenPersistFullDraft() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) }; let data=try pdf(), original=record(data:data)
        let model=TableEditorModel(storage:root);model.open(data:data,page:0,identity:"test",sourcePath:nil,title:"test",saved:original);try await wait(model)
        model.setCell(row:1,column:0,text:"changed 😀");XCTAssertEqual(model.draft?.rows[1][0],"changed 😀");model.undo();XCTAssertEqual(model.draft?.rows[1][0],"one")
        model.redo();let stored=try TableDraftStore.read(TableDraftStore.url(original.id,storage:root));XCTAssertEqual(stored.rows[1][0],"changed 😀")
        let other=TableEditorModel(storage:root);other.open(data:data,page:0,identity:"test",sourcePath:nil,title:"test",saved:stored);try await wait(other);XCTAssertEqual(other.draft?.rows,stored.rows)
    }
    @MainActor func testGridChangeKeepsManualCellsUntilRegeneratedAndCanUndo() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let data=try pdf(), draft=record(data:data), model=TableEditorModel(storage:root)
        model.open(data:data,page:0,identity:"test",sourcePath:nil,title:"test",saved:draft);try await wait(model)
        var grid=draft.grid;try grid.move(vertical:true,index:1,value:0.6);model.changeGrid(grid)
        XCTAssertTrue(model.draft!.needsRegeneration);XCTAssertEqual(model.draft?.rows,draft.rows);model.undo();XCTAssertFalse(model.draft!.needsRegeneration)
    }
    @MainActor func testChangedPDFKeepsStaleDraftWithoutApplyingOldGeometry() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let draft=record(data:try pdf()),model=TableEditorModel(storage:root)
        model.open(data:try pdf("other"),page:0,identity:"test",sourcePath:nil,title:"test",saved:draft);try await wait(model);XCTAssertTrue(model.stale)
        model.changeGrid(TableGrid());XCTAssertEqual(model.draft?.grid,draft.grid);XCTAssertEqual(model.draft?.rows,draft.rows)
    }
    @MainActor func testCancelledTableLoadDoesNotPublishPartialDraft() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let model=TableEditorModel(storage:root)
        model.open(data:try pdf(),page:0,identity:"test",sourcePath:nil,title:"test",saved:nil);model.cancel();try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertFalse(model.working);XCTAssertNil(model.draft)
    }
    @MainActor func testProjectRecoveryCarriesTableDraftAndExactPDFBytes() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let data=try pdf(),w=Workspace(storage:root);w.document=PDFDocument(data:data)!;w.cachedPDF=data
        w.tableDrafts=[record(data:data)];let archive=try ProjectContainer.decode(ProjectContainer.encode(w.snapshot()));let restored=Workspace(storage:root);try restored.restore(archive)
        XCTAssertEqual(restored.tableDrafts[0].rows,w.tableDrafts[0].rows);XCTAssertEqual(try restored.pdfData(),data);XCTAssertEqual(restored.tableDrafts[0].identity,restored.tableIdentity)
    }
    @MainActor func testDraftIdentityMovesToSavedDestinationAndSameNamesRemainSeparate() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let data=try pdf(),a=Workspace(storage:root),b=Workspace(storage:root)
        a.tableDrafts=[record(data:data)];a.sourceURL=root.appendingPathComponent("one/book.pdf");try a.persistTableDrafts();b.sourceURL=root.appendingPathComponent("two/book.pdf");b.loadTableDrafts()
        XCTAssertTrue(b.tableDrafts.isEmpty);XCTAssertEqual(try TableDraftStore.list(storage:root)[0].identity,a.tableIdentity)
    }
    func testTableDraftValidationRejectsBrokenOrOversizedShape() throws {
        var draft=record(data:try pdf());draft.rows=[["a"],["b","c"]];XCTAssertThrowsError(try draft.validate())
        draft.rows=Array(repeating:Array(repeating:"",count:100),count:21);XCTAssertThrowsError(try draft.validate())
    }
    func testCrossPageJoinRemovesOnlyExplicitIdenticalHeaders() throws {
        let first=[["A","B"],["1","2"]], second=[["A","B"],["3","4"]]
        XCTAssertEqual(try TableMerge.joined([first,second],removeHeaders:true),[["A","B"],["1","2"],["3","4"]])
        XCTAssertEqual(try TableMerge.joined([first,second],removeHeaders:false).count,4)
        XCTAssertThrowsError(try TableMerge.joined([first,[["x"]]],removeHeaders:true))
    }
    func tablePDF() throws -> Data {
        let data=NSMutableData();var box=CGRect(x:0,y:0,width:600,height:600);let ctx=CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:&box,nil)!
        for values in [["A","B","one","two"],["A","B","three","four"]] {
            ctx.beginPDFPage(nil);ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(box)
            ctx.setStrokeColor(CGColor(gray:0,alpha:1));ctx.setLineWidth(2)
            for x in [60,300,540] {ctx.move(to:CGPoint(x:x,y:150));ctx.addLine(to:CGPoint(x:x,y:450))}
            for y in [150,300,450] {ctx.move(to:CGPoint(x:60,y:y));ctx.addLine(to:CGPoint(x:540,y:y))};ctx.strokePath()
            for (text,x,y) in [("Before body",70,520),(values[0],100,380),(values[1],340,380),(values[2],100,220),(values[3],340,220),("After body",70,70)] {
                let string=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,24,nil)])
                ctx.textPosition=CGPoint(x:x,y:y);CTLineDraw(CTLineCreateWithAttributedString(string),ctx)
            };ctx.endPDFPage()
        };ctx.closePDF();return data as Data
    }
    func testActualCrossPageExtractionFollowsColumnsAndHeaderChoice() throws {
        let data=try tablePDF();var draft=record(data:data);draft.rows=[["A","B"],["one","two"]]
        let result=try TableMerge.extract(data:data,current:draft,pages:[0,1],removeHeaders:true,languages:["en-US"])
        XCTAssertEqual(result.rows,[["A","B"],["one","two"],["three","four"]]);XCTAssertEqual(result.regions.map(\.page),[0,1])
        XCTAssertThrowsError(try TableMerge.extract(data:data,current:draft,pages:[1],removeHeaders:false,languages:[]))
    }
    func insertion(data:Data) -> WordTableInsertion {
        WordTableInsertion(id:UUID(),sourceDigest:OCRPageCache.digest(data),page:0,regions:[TableSourceRegion(page:0,rect:CGRect(x:0.1,y:0.25,width:0.8,height:0.5)),TableSourceRegion(page:1,rect:CGRect(x:0.1,y:0.25,width:0.8,height:0.5))],rows:[["A","B"],["one","two"],["three","four"]])
    }
    func testWordContainsTableOnceAtSourcePositionWithoutDuplicatedTableText() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let data=try tablePDF(),doc=PDFDocument(data:data)!,file=root.appendingPathComponent("mixed.docx")
        var options=WordExportOptions();options.content = .textOnly;options.tables=[insertion(data:data)]
        _=try WordExport.write(doc,pages:[0,1],outline:[],options:options,to:file,sourceDigest:OCRPageCache.digest(data))
        let xml=try WordExportTests().unzip(["-p",file.path,"word/document.xml"])
        XCTAssertEqual(xml.components(separatedBy:"<w:tbl>").count-1,1)
        XCTAssertEqual(xml.components(separatedBy:">three</w:t>").count-1,1)
        let before=try XCTUnwrap(xml.range(of:"Before body")),table=try XCTUnwrap(xml.range(of:"<w:tbl>")),after=try XCTUnwrap(xml.range(of:"After body"))
        XCTAssertTrue(before.lowerBound < table.lowerBound && table.lowerBound < after.lowerBound)
        let preview=try WordCleanup.inspect(doc,pages:[0,1],options:options,regions:[:],sourceDigest:OCRPageCache.digest(data)).pages
        XCTAssertTrue(preview[0].blocks!.contains { if case .table = $0 { return true };return false })
        XCTAssertFalse(preview[1].paragraphs.map(\.text).joined().contains("three"))
    }
    func testWordRejectsStaleOverlappingPartialAndHandEditedTablePages() throws {
        let data=try tablePDF(),doc=PDFDocument(data:data)!,table=insertion(data:data);var options=WordExportOptions();options.tables=[table]
        XCTAssertThrowsError(try WordTables.validate([table],document:doc,pages:[0,1],options:options,sourceDigest:"changed"))
        XCTAssertThrowsError(try WordTables.validate([table],document:doc,pages:[1],options:options,sourceDigest:table.sourceDigest))
        XCTAssertThrowsError(try WordTables.validate([table,table],document:doc,pages:[0,1],options:options,sourceDigest:table.sourceDigest))
        options.editedText=[0:"manual"];XCTAssertThrowsError(try WordTables.validate([table],document:doc,pages:[0,1],options:options,sourceDigest:table.sourceDigest))
    }
    func testDisableTablesKeepsOldExportAndTableXMLPreservesMultilineEscaping() throws {
        let data=try tablePDF(),doc=PDFDocument(data:data)!;var options=WordExportOptions();options.tables=[insertion(data:data)];options.includeTables=false
        let pages=try WordCleanup.inspect(doc,pages:[0,1],options:options,regions:[:]).pages;XCTAssertNil(pages[0].blocks)
        let xml=WordTables.xml([["A&B"],["line1\nline2😀"]]);XCTAssertTrue(xml.contains("A&amp;B"));XCTAssertTrue(xml.contains("line2😀"));XCTAssertTrue(xml.contains("<w:tblHeader/>"))
    }
    @MainActor func testWordOptionsCollectOnlyMarkedValidatedDrafts() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let w=Workspace(storage:root);var draft=record(data:try pdf());draft.includeInWord=true;w.tableDrafts=[draft]
        XCTAssertEqual(try w.wordOptionsWithTables().tables?.count,1);w.tableDrafts[0].needsRegeneration=true;XCTAssertThrowsError(try w.wordOptionsWithTables())
        w.wordOptions.content = .imagesOnly;XCTAssertNil(try w.wordOptionsWithTables().tables)
    }
    func template(_ page: PDFPage) -> FormTemplate {
        FormTemplate(name:"常用表单",pageSize:FormTemplate.displaySize(page),fields:[FormTemplateField(name:"姓名",kind:.text,rect:CGRect(x:0.1,y:0.2,width:0.5,height:0.08)),FormTemplateField(name:"确认",kind:.check,rect:CGRect(x:0.1,y:0.4,width:0.05,height:0.05))])
    }
    @MainActor func testFlatPDFTemplateCreatesFillableFieldsRoundTripsAndUndo() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let w=Workspace(storage:root);w.document=DocumentServicesTests().fixture();let page=w.document.page(at:0)!,form=template(page)
        try w.applyFormTemplate(form,page:0,from:w.revision);let fields=PDFForms.fields(w.document);XCTAssertEqual(fields.count,2)
        try w.applyFormValues([fields[0].id:"Test Name",fields[1].id:"1"],from:w.revision)
        let restored=PDFForms.fields(PDFDocument(data:try w.pdfData())!);XCTAssertEqual(restored.map(\.value),["Test Name","1"])
        w.undo();w.undo();XCTAssertTrue(PDFForms.fields(w.document).isEmpty)
    }
    @MainActor func testTemplateApplyRejectsDuplicateNameWrongAspectAndStaleRevisionAtomically() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let w=Workspace(storage:root);w.document=DocumentServicesTests().fixture();var form=template(w.document.page(at:0)!)
        form.fields[1].name=form.fields[0].name;XCTAssertThrowsError(try w.applyFormTemplate(form,page:0,from:w.revision));XCTAssertTrue(PDFForms.fields(w.document).isEmpty)
        form=template(w.document.page(at:0)!);form.pageSize=CGSize(width:100,height:100);XCTAssertThrowsError(try w.applyFormTemplate(form,page:0,from:w.revision))
        form=template(w.document.page(at:0)!);XCTAssertThrowsError(try w.applyFormTemplate(form,page:0,from:UUID()))
        try w.applyFormTemplate(form,page:0,from:w.revision);XCTAssertThrowsError(try w.applyFormTemplate(form,page:0,from:w.revision));XCTAssertEqual(PDFForms.fields(w.document).count,2)
    }
    @MainActor func testTemplateCoordinatesRespectCropAndPageRotation() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let w=Workspace(storage:root);w.document=DocumentServicesTests().fixture();let page=w.document.page(at:0)!
        page.setBounds(CGRect(x:20,y:30,width:250,height:350),for:.cropBox);page.rotation=90;let form=template(page)
        try w.applyFormTemplate(form,page:0,from:w.revision)
        let fraction=OrderedText.fraction(ofPageRect:page.annotations[0].bounds,cropBox:page.bounds(for:.cropBox),rotation:90)
        XCTAssertEqual(Double(fraction.minX),0.1,accuracy:0.001);XCTAssertEqual(Double(1-fraction.maxY),0.2,accuracy:0.001)
    }
    func testTemplateStoreKeepsNamesAndPositionsWithoutFilledPersonalValues() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let form=template(DocumentServicesTests().fixture().page(at:0)!)
        try FormTemplateStore.save(form,storage:root);XCTAssertEqual(try FormTemplateStore.list(storage:root),[form])
        let bytes=try String(contentsOf:FormTemplateStore.folder(root).appendingPathComponent(form.id.uuidString+".json"));XCTAssertFalse(bytes.contains("widgetStringValue"))
    }
    @MainActor func testRecoveryCatalogListsNamedConflictAndDraftKindsWithoutReadingPDFBlob() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("original.pdf"),data=try pdf();try data.write(to:file)
        let w=Release032Tests().workspace(root,file,data);try w.setWordDraft("word text",page:0);try TableDraftStore.write(record(data:data,path:file.path),storage:root)
        let conflict=root.appendingPathComponent("Conflicts/a.kongfolio");try FileManager.default.createDirectory(at:conflict.deletingLastPathComponent(),withIntermediateDirectories:true);try w.snapshot().write(conflict)
        let items=try RecoveryCatalog.list(storage:root);XCTAssertTrue(items.contains { $0.kind == .word && $0.sourcePath == file.path });XCTAssertTrue(items.contains { $0.kind == .table });XCTAssertTrue(items.contains { $0.kind == .conflictPDF && $0.title==w.title })
        let header=try RecoveryCatalog.archiveHeader(conflict);XCTAssertTrue(header.pdf.isEmpty);XCTAssertEqual(header.sourcePath,file.path)
    }
    @MainActor func testRecoveredPDFIsIndependentAndNeverBoundToOriginalSavePath() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("source.pdf"),data=try pdf();try data.write(to:file)
        let w=Release032Tests().workspace(root,file,data);w.rotate();let archive=root.appendingPathComponent("copy.kongfolio");try w.snapshot().write(archive)
        let item=RecoveryItem(url:archive,kind:.conflictPDF,title:"copy",modified:Date()),store=WorkspaceStore(storage:root);try store.openRecoveryCopy(item)
        let copy=try XCTUnwrap(store.activeWorkspace);XCTAssertNil(copy.sourceURL);XCTAssertNil(copy.projectURL);XCTAssertTrue(copy.dirty);XCTAssertEqual(copy.document.page(at:0)!.rotation,90)
        copy.rotate();XCTAssertEqual(try Data(contentsOf:file),data)
    }
    @MainActor func testStaleTableRecoveryOpensMarkdownAndKeepsStoredDraft() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("a.pdf"),data=try pdf(),draft=record(data:data,path:file.path)
        try TableDraftStore.write(draft,storage:root);try pdf("changed").write(to:file)
        let url=TableDraftStore.url(draft.id,storage:root),old=try Data(contentsOf:url),item=RecoveryItem(url:url,kind:.table,title:"table",sourcePath:file.path,modified:Date()),store=WorkspaceStore(storage:root)
        let preview=try RecoveryCatalog.preview(item);XCTAssertTrue(preview.sourceStatus.contains("不同"));try store.openRecoveryCopy(item,payload:preview.payload)
        XCTAssertTrue(store.activeNote!.text.contains("one"));XCTAssertNil(store.activeNote?.fileURL);XCTAssertEqual(try Data(contentsOf:url),old)
    }
    @MainActor func testMatchingTableRecoveryClonesRecordAndKeepsOriginal() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("a.pdf"),data=try pdf();try data.write(to:file);let draft=record(data:data,path:file.path);try TableDraftStore.write(draft,storage:root)
        let url=TableDraftStore.url(draft.id,storage:root),item=RecoveryItem(url:url,kind:.table,title:"table",sourcePath:file.path,modified:Date()),store=WorkspaceStore(storage:root)
        try store.openRecoveryCopy(item);let copy=try XCTUnwrap(store.activeWorkspace);XCTAssertNil(copy.sourceURL);XCTAssertFalse(copy.tableDrafts[0].id == draft.id);XCTAssertEqual(try TableDraftStore.read(url).identity,draft.identity)
    }
    @MainActor func testRecoveredTextPreservesLocalImageBaseWithoutOriginalFileBinding() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let source=root.appendingPathComponent("note.md"),image=root.appendingPathComponent("image.png");try Release029Tests().png().write(to:image)
        let note=MarkdownNote(text:"![图](image.png)",fileURL:source,dirty:true,storage:root);try note.writeBackup()
        let item=RecoveryItem(url:note.backupURL,kind:.note,title:"note",sourcePath:source.path,modified:Date()),store=WorkspaceStore(storage:root);try store.openRecoveryCopy(item)
        let recovered=try XCTUnwrap(store.activeNote);XCTAssertNil(recovered.fileURL);XCTAssertEqual(try recovered.renderDocument().pageCount,1)
        let destination=root.appendingPathComponent("new/note.md");try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true);try recovered.write(to:destination)
        XCTAssertTrue(recovered.text.contains("note-assets"));XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
    }
    func testCorruptRecoveryRemainsListedAndFailsPreviewWithoutDeletion() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("TableDrafts/bad.json");try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("bad".utf8).write(to:file)
        let items=try RecoveryCatalog.list(storage:root);XCTAssertEqual(items.count,1);XCTAssertThrowsError(try RecoveryCatalog.preview(items[0]));XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    @MainActor func testLegacyWordDraftCanFindSourceFromKnownPaths() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("legacy.pdf"),data=try pdf();try data.write(to:file)
        let folder=root.appendingPathComponent("WordDrafts");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let key=OCRPageCache.digest(Data(file.standardizedFileURL.path.utf8))
        var options=WordExportOptions();options.editedText=[0:"legacy body"];try JSONEncoder().encode(WordDraftArchive(digest:OCRPageCache.digest(data),options:options)).write(to:folder.appendingPathComponent(key+".json"))
        let items=try RecoveryCatalog.list(storage:root,knownPaths:[file.path]);XCTAssertEqual(items[0].sourcePath,file.path);XCTAssertTrue(try RecoveryCatalog.preview(items[0]).text.contains("legacy body"))
    }
    func testTaskCancellationPreservesExistingDestinationAndRemovesStaging() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("output.txt");try Data("old".utf8).write(to:file);let expected=try FileBaseline.capture(file)
        let cancelled=await Task.detached { () -> Bool in
            do { try DocumentTaskOutput.write(to:file,expected:expected) { try Data("new".utf8).write(to:$0);withUnsafeCurrentTask { $0?.cancel() } };return false }
            catch is CancellationError {return true} catch {return false}
        }.value
        XCTAssertTrue(cancelled);XCTAssertEqual(try String(contentsOf:file),"old");XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasSuffix("partial") })
    }
    func testTaskCommitRefusesDestinationChangedDuringGeneration() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("output.txt");try Data("old".utf8).write(to:file);let expected=try FileBaseline.capture(file)
        XCTAssertThrowsError(try DocumentTaskOutput.write(to:file,expected:expected) { try Data("mine".utf8).write(to:$0);try Data("external".utf8).write(to:file) })
        XCTAssertEqual(try String(contentsOf:file),"external")
    }
    @MainActor func testBackgroundTasksAllowOtherTabsAndCancellation() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let store=WorkspaceStore(storage:root),w=store.newPDF(),queue=store.documentTasks
        let id=try queue.start("cancel test") { progress in for i in 0..<100 { try Task.checkCancellation();progress(Double(i)/100);Thread.sleep(forTimeInterval:0.002) };return DocumentTaskResult(message:"done") }
        store.newNote();XCTAssertNotNil(store.activeNote);XCTAssertFalse(w.busy);queue.cancel(id);try await wait(queue);XCTAssertEqual(queue.items[0].state,.cancelled)
    }
    @MainActor func testQueueBoundsConcurrentJobsAndRunsCompletionOnSuccess() async throws {
        let queue=DocumentTaskQueue();var completed=false
        _=try queue.start("first",completion:{ _ in completed=true }) { _ in Thread.sleep(forTimeInterval:0.05);return DocumentTaskResult(message:"done") }
        _=try queue.start("second") { _ in Thread.sleep(forTimeInterval:0.05);return DocumentTaskResult(message:"done") }
        XCTAssertThrowsError(try queue.start("third") { _ in DocumentTaskResult(message:"no") });try await wait(queue);XCTAssertTrue(completed);XCTAssertTrue(queue.items.allSatisfy { $0.state == .finished })
    }
    @MainActor func testBackgroundFormExportKeepsSourceAndProducesFlattenedResult() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("forms.pdf"),w=Workspace(storage:root);w.document=try Release032Tests().forms();try w.pdfData().write(to:file);w.sourceURL=file
        let before=try Data(contentsOf:file),queue=DocumentTaskQueue(),out=root.appendingPathComponent("fixed.pdf");try w.startFlattenedForm(to:out,queue:queue);try await wait(queue)
        XCTAssertEqual(queue.items[0].state,.finished);XCTAssertTrue(PDFForms.fields(PDFDocument(url:out)!).isEmpty);XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertThrowsError(try w.startFlattenedForm(to:file,queue:queue))
    }
    @MainActor func testBackgroundMergeWritesDraftAndUpdatesWorkspaceWithoutBlocking() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let data=try tablePDF(),w=Workspace(storage:root);w.document=PDFDocument(data:data)!;w.cachedPDF=data;var draft=record(data:data);draft.rows=[["A","B"],["one","two"]];w.tableDrafts=[draft]
        let queue=DocumentTaskQueue();try w.startTableMerge(draft,pages:[0,1],removeHeaders:true,queue:queue);XCTAssertFalse(w.busy);try await wait(queue)
        XCTAssertEqual(queue.items[0].state,.finished);XCTAssertEqual(w.tableDrafts[0].rows.count,3);XCTAssertEqual(w.tableDrafts[0].regions.count,2)
    }
    @MainActor func testNewCommandsRespectContextAndSearchAliases() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let store=WorkspaceStore(storage:root);store.bootstrap()
        XCTAssertNil(store.unavailableReason(.recoveryCenter));XCTAssertNil(store.unavailableReason(.backgroundJobs));XCTAssertNotNil(store.unavailableReason(.formTemplate))
        XCTAssertTrue(FolioCommand.ranked(query:"模板",recent:[]).contains(.formTemplate));store.performCommand(.recoveryCenter);XCTAssertTrue(store.showRecoveryCenter)
    }
    @MainActor func testTwoTableEditorsCannotOverwriteEachOthersDraftChanges() async throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let data=try pdf(),draft=record(data:data);try TableDraftStore.write(draft,storage:root)
        let a=TableEditorModel(storage:root),b=TableEditorModel(storage:root)
        a.open(data:data,page:0,identity:"test",sourcePath:nil,title:"test",saved:draft);b.open(data:data,page:0,identity:"test",sourcePath:nil,title:"test",saved:draft);try await wait(a);try await wait(b)
        a.setCell(row:1,column:0,text:"first editor")
        b.setCell(row:1,column:0,text:"old editor overwrite")
        XCTAssertEqual(try TableDraftStore.read(TableDraftStore.url(draft.id,storage:root)).rows[1][0],"first editor");XCTAssertTrue(b.message.contains("其他窗口"))
    }
    @MainActor func testSavingDocumentDoesNotReplaceNewerTableDraftAndSaveAsKeepsOriginalDraft() throws {
        let root=try folder();defer { try? FileManager.default.removeItem(at:root) };let file=root.appendingPathComponent("old.pdf"),data=try pdf(),w=Workspace(storage:root);w.sourceURL=file
        var draft=record(data:data,path:file.path);w.tableDrafts=[draft];try TableDraftStore.write(draft,storage:root)
        draft.rows[1][0]="newer";draft.modified=Date().addingTimeInterval(1);try TableDraftStore.write(draft,storage:root)
        try w.persistTableDrafts();XCTAssertEqual(w.tableDrafts[0].rows[1][0],"newer")
        w.sourceURL=root.appendingPathComponent("copy.pdf");try w.persistTableDrafts();XCTAssertFalse(w.tableDrafts[0].id == draft.id);XCTAssertEqual(try TableDraftStore.read(TableDraftStore.url(draft.id,storage:root)).sourcePath,file.path)
    }

}
