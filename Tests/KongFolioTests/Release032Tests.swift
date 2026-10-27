import XCTest
import AppKit
import CoreText
import PDFKit
@testable import KongFolio

final class Release032Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func pdf(_ text: String = "source history") throws -> Data { try Release027Tests().pdf([text]) }
    @MainActor func workspace(_ root: URL, _ file: URL, _ bytes: Data) -> Workspace {
        let w = Workspace(storage: root); w.bootstrap(); w.load([file], prepared: .documents([bytes])); return w
    }
    @MainActor func testWordDraftSurvivesReopenAndExportsRecoveredText() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"), bytes = try pdf(); try bytes.write(to: file)
        let a = workspace(root, file, bytes); try a.setWordDraft("第一章 恢复草稿\n\nrecovered body", page: 0)
        let b = workspace(root, file, bytes); try b.validateWordDraft()
        XCTAssertEqual(b.wordOptions.editedText?[0], "第一章 恢复草稿\n\nrecovered body")
        var options = b.wordOptions; options.content = .textOnly
        let word = root.appendingPathComponent("recovered.docx"); _ = try WordExport.write(b.document, pages: [0], outline: [], options: options, to: word)
        XCTAssertTrue(try WordExportTests().unzip(["-p", word.path, "word/document.xml"]).contains("recovered body"))
    }
    @MainActor func testWordDraftSourceChangeKeepsReadableDraftButRefusesExportUse() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"), bytes = try pdf(); try bytes.write(to: file)
        let a = workspace(root, file, bytes); try a.setWordDraft("keep this draft", page: 0)
        let changed = try pdf("changed source"); try changed.write(to: file)
        let b = workspace(root, file, changed)
        XCTAssertThrowsError(try b.validateWordDraft()); XCTAssertTrue(b.wordDraftText.contains("keep this draft"))
        b.clearWordDraft(); try b.validateWordDraft(); XCTAssertFalse(FileManager.default.fileExists(atPath: b.wordDraftURL.path))
    }
    @MainActor func testWordDraftInRecoveryContainerRetainsRevisionAssociation() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = Workspace(storage: root); a.document = PDFDocument(data: try pdf())!
        try a.setWordDraft("recovery body", page: 0)
        let archive = try ProjectContainer.decode(ProjectContainer.encode(a.snapshot()))
        let b = Workspace(storage: root); try b.restore(archive)
        try b.validateWordDraft(); XCTAssertEqual(b.wordOptions.editedText?[0], "recovery body")
    }
    @MainActor func testDraftsForSameNamedDocumentsDoNotMix() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("one.pdf"), b = root.appendingPathComponent("two.pdf"), data = try pdf()
        try data.write(to: a); try data.write(to: b)
        let first = workspace(root, a, data); try first.setWordDraft("one only", page: 0)
        let second = workspace(root, b, data); XCTAssertNil(second.wordOptions.editedText); XCTAssertFalse(first.wordDraftURL == second.wordDraftURL)
    }
    func testBaselineDetectsContentChangeWithSameTimestampAndSize() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt"); try Data("abc".utf8).write(to: file)
        let date = Date(timeIntervalSince1970: 12345); try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let baseline = try FileBaseline.capture(file)
        try Data("xyz".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        XCTAssertThrowsError(try baseline.verify(file))
    }
    func testCoordinatedWriteRechecksBaselineAndDoesNotTouchConflictingBytes() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt"); try Data("old".utf8).write(to: file)
        let baseline = try FileBaseline.capture(file); try Data("external".utf8).write(to: file)
        XCTAssertThrowsError(try baseline.writing(file) { try Data("mine".utf8).write(to: $0) })
        XCTAssertEqual(try String(contentsOf: file), "external")
    }
    @MainActor func testPDFAutosaveConflictKeepsBothVersionsAndCanSaveCopy() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"), data = try pdf(); try data.write(to: file)
        let w = workspace(root, file, data); w.rotate()
        let external = try pdf("external source"); try external.write(to: file)
        XCTAssertFalse(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.saveConflict); XCTAssertTrue(w.dirty)
        XCTAssertEqual(try Data(contentsOf: file), external); XCTAssertTrue(FileManager.default.fileExists(atPath: w.recoveryURL.path))
        let copy = root.appendingPathComponent("mine.pdf"); try w.saveConflictCopy(to: copy)
        XCTAssertEqual(PDFDocument(url: copy)!.page(at: 0)!.rotation, 90); XCTAssertEqual(try Data(contentsOf: file), external)
        XCTAssertFalse(w.saveConflict); XCTAssertFalse(w.dirty)
    }
    @MainActor func testConflictReloadArchivesUnsavedWorkBeforeLoadingExternalFile() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"), data = try pdf(); try data.write(to: file)
        let w = workspace(root, file, data); w.rotate(); let external = try pdf("external source"); try external.write(to: file)
        XCTAssertFalse(w.saveDirectly(askForDestination: false)); w.reloadAfterConflict()
        XCTAssertTrue(w.document.string!.contains("external source")); XCTAssertFalse(w.saveConflict)
        let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Conflicts"), includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 1); XCTAssertEqual(PDFDocument(data: try ProjectArchive.read(archives[0]).pdf)!.page(at: 0)!.rotation, 90)
    }
    @MainActor func testRecoveryPreservesOriginalBaselineAgainstLaterExternalEdit() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"), data = try pdf(); try data.write(to: file)
        let a = workspace(root, file, data); a.rotate(); let archive = try a.snapshot()
        let external = try pdf("changed after crash"); try external.write(to: file)
        let b = Workspace(storage: root); try b.restore(archive)
        XCTAssertFalse(b.saveDirectly(askForDestination: false)); XCTAssertTrue(b.saveConflict); XCTAssertEqual(try Data(contentsOf: file), external)
    }
    @MainActor func testProjectFileConflictDoesNotOverwriteExternalProject() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.kongfolio"), w = Workspace(storage: root)
        w.document = PDFDocument(data: try pdf())!; w.projectURL = file; XCTAssertTrue(w.saveProject(background: false)); w.rotate()
        var other = try ProjectArchive.read(file); other.title = "external"; try other.write(file)
        let external = try Data(contentsOf: file)
        XCTAssertFalse(w.saveProject(background: false)); XCTAssertTrue(w.saveConflict); XCTAssertEqual(try Data(contentsOf: file), external)
    }
    @MainActor func testTextFileConflictAndRecoveryBaseline() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.md"); try "old".write(to: file, atomically: true, encoding: .utf8)
        let note = try MarkdownNote.open(file, storage: root); note.text = "mine"; try note.writeBackup()
        try "external".write(to: file, atomically: true, encoding: .utf8)
        let recovered = MarkdownNote.restoreBackups(storage: root)[0]
        XCTAssertFalse(recovered.save()); XCTAssertTrue(recovered.saveConflict); XCTAssertEqual(try String(contentsOf: file), "external")
        let copy = root.appendingPathComponent("mine.md"); try recovered.write(to: copy); XCTAssertEqual(try String(contentsOf: copy), "mine")
    }
    @MainActor func testDeletedOriginalIsAConflict() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"), data = try pdf(); try data.write(to: file)
        let w = workspace(root, file, data); w.rotate(); try FileManager.default.removeItem(at: file)
        XCTAssertFalse(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.saveConflict); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testTableExtractUsesGeometryNotTextLayerOrderAndKeepsEmptyCells() throws {
        let pieces = [TablePiece(text: "四", box: CGRect(x: 0.7, y: 0.7, width: 0.05, height: 0.05)), TablePiece(text: "一", box: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05)), TablePiece(text: "二", box: CGRect(x: 0.7, y: 0.1, width: 0.05, height: 0.05))]
        let table = try TableExtraction.extract(pieces, x: [0,0.5,1], y: [0,0.5,1])
        XCTAssertEqual(table.rows, [["一","二"],["","四"]])
    }
    func testTableRegionExcludesOutsideTextAndPreservesMultiline() throws {
        let pieces = [TablePiece(text: "out", box: CGRect(x: 0, y: 0, width: 0.02, height: 0.02)), TablePiece(text: "top", box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.05)), TablePiece(text: "bottom", box: CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.05))]
        XCTAssertEqual(try TableExtraction.extract(pieces, x: [0.2,0.8], y: [0.2,0.8]).rows, [["top\nbottom"]])
    }
    func testTableBoundariesValidatePercentagesAndCellLimit() throws {
        XCTAssertEqual(try TableExtraction.boundaries("50，25", region: 0...1), [0,0.25,0.5,1])
        XCTAssertThrowsError(try TableExtraction.boundaries("NaN", region: 0...1))
        XCTAssertThrowsError(try TableExtraction.boundaries("10,10", region: 0...1))
        XCTAssertThrowsError(try TableExtraction.boundaries("10", region: 0.2...0.8))
        XCTAssertThrowsError(try TableExtraction.extract([], x: [0,0.5,0.5,1], y: [0,1]))
        XCTAssertThrowsError(try TableExtraction.extract([], x: (0...50).map { Double($0)/50 }, y: (0...50).map { Double($0)/50 }))
    }
    func testTableCSVAndMarkdownEscapeAndWordContainsRealTable() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let table = ExtractedTable(rows: [["甲|乙","a\"b"],["多\n行","😀"]])
        XCTAssertTrue(table.markdown.contains("甲\\|乙")); XCTAssertTrue(table.markdown.contains("多<br>行")); XCTAssertTrue(table.csv.contains("\"a\"\"b\""))
        let word = root.appendingPathComponent("table.docx"); try table.writeWord(to: word)
        let xml = try WordExportTests().unzip(["-p", word.path, "word/document.xml"])
        XCTAssertTrue(xml.contains("<w:tbl>")); XCTAssertTrue(xml.contains("<w:br/>")); XCTAssertTrue(xml.contains("😀"))
    }
    func gridImage() throws -> CGImage {
        let ctx = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 600,height: 600))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(3)
        for v in [60,300,540] { ctx.move(to: CGPoint(x: v,y: 60)); ctx.addLine(to: CGPoint(x: v,y: 540)); ctx.move(to: CGPoint(x: 60,y: v)); ctx.addLine(to: CGPoint(x: 540,y: v)) }; ctx.strokePath()
        return ctx.makeImage()!
    }
    func testRuledTableSuggestsInternalGridLines() throws {
        let result = try TableExtraction.suggest([], image: gridImage(), region: CGRect(x: 0.1,y: 0.1,width: 0.8,height: 0.8))
        XCTAssertEqual(result.x.count, 1); XCTAssertEqual(result.y.count, 1); XCTAssertEqual(result.x[0], 0.5, accuracy: 0.01)
    }
    func testOCRTableBoxesMapToTopLeftCoordinates() {
        let piece = TableExtraction.pieces([RecognizedLine(text: "top", box: CGRect(x: 0.1,y: 0.8,width: 0.2,height: 0.1))])[0]
        XCTAssertEqual(Double(piece.box.minY), 0.1, accuracy: 0.001)
    }
    func forms() throws -> PDFDocument {
        let document = PDFDocument(data: try pdf())!, page = document.page(at: 0)!
        let text = PDFAnnotation(bounds: CGRect(x: 20,y: 220,width: 200,height: 30), forType: .widget, withProperties: nil)
        text.widgetFieldType = .text; text.fieldName = "姓名"; text.maximumLength = 20; text.font = .systemFont(ofSize: 14); text.fontColor = .black; text.widgetStringValue = "old"; page.addAnnotation(text)
        let check = PDFAnnotation(bounds: CGRect(x: 20,y: 170,width: 20,height: 20), forType: .widget, withProperties: nil)
        check.widgetFieldType = .button; check.widgetControlType = .checkBoxControl; check.fieldName = "确认"; check.buttonWidgetStateString = "Yes"; check.buttonWidgetState = .offState; page.addAnnotation(check)
        let choice = PDFAnnotation(bounds: CGRect(x: 20,y: 110,width: 180,height: 30), forType: .widget, withProperties: nil)
        choice.widgetFieldType = .choice; choice.fieldName = "地区"; choice.choices = ["北京","上海"]; choice.values = ["BJ","SH"]; choice.widgetStringValue = "BJ"; page.addAnnotation(choice)
        return document
    }
    @MainActor func testFormFillSurvivesSavingAndSupportsUndo() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let w = Workspace(storage: root); w.document = try forms()
        let fields = PDFForms.fields(w.document); XCTAssertEqual(fields.count, 3)
        try w.applyFormValues([fields[0].id:"张三",fields[1].id:"1",fields[2].id:"SH"], from: w.revision)
        let reopened = PDFDocument(data: try w.pdfData())!, restored = PDFForms.fields(reopened)
        XCTAssertEqual(restored.map(\.value), ["张三","1","SH"])
        w.undo(); XCTAssertEqual(PDFForms.fields(w.document).map(\.value), ["old","0","BJ"])
    }
    @MainActor func testInvalidOrReadonlyFormChangesAreAtomicAndRevisionChecked() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let w = Workspace(storage: root); w.document = try forms(); let fields = PDFForms.fields(w.document)
        XCTAssertThrowsError(try w.applyFormValues([fields[0].id:"changed",fields[2].id:"invalid"], from: w.revision))
        XCTAssertEqual(PDFForms.fields(w.document)[0].value, "old")
        w.document.page(at: 0)!.annotations[0].isReadOnly = true
        XCTAssertThrowsError(try w.applyFormValues([fields[0].id:"new"], from: w.revision))
        XCTAssertThrowsError(try w.applyFormValues([fields[1].id:"1"], from: UUID()))
    }
    @MainActor func testFormLengthGuardAndRadioExclusion() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let w = Workspace(storage: root); w.document = try forms(); let fields = PDFForms.fields(w.document)
        XCTAssertThrowsError(try w.applyFormValues([fields[0].id:String(repeating:"字",count:21)], from: w.revision))
        let a = PDFFormField(page: 0,index: 0,name:"radio",kind:"单选",value:"0",choices:[],exports:[],readOnly:false,maximumLength:0,password:false)
        var b = a; b.index = 1
        XCTAssertThrowsError(try PDFForms.validate([a,b], values:[a.id:"1",b.id:"1"]))
    }
    func testFlattenedFormsHaveNoWidgetsKeepPageSizeAndVisibleAppearance() throws {
        let original = try forms(); original.page(at: 0)!.rotation = 90
        let flat = try PDFForms.flattened(original)
        XCTAssertEqual(flat.pageCount, 1); XCTAssertTrue(PDFForms.fields(flat).isEmpty)
        XCTAssertEqual(flat.page(at: 0)!.bounds(for: .mediaBox).size, CGSize(width: 400,height: 300))
        let image = try DocumentServices.render(flat.page(at: 0)!, maxDimension: 500)
        XCTAssertTrue(image.width > 0); XCTAssertEqual(PDFForms.fields(original).count, 3)
    }
    @MainActor func testFlattenedFormCannotReplaceSource() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("forms.pdf"), w = Workspace(storage: root); w.document = try forms(); try w.pdfData().write(to: file); w.sourceURL = file
        XCTAssertThrowsError(try w.exportFlattenedForm(to: file))
    }
    func testCommandSearchChineseAndEnglishAndRecentOrder() {
        XCTAssertEqual(FolioCommand.ranked(query:"导出 WORD", recent:[]), [.exportWord])
        XCTAssertEqual(FolioCommand.ranked(query:"csv", recent:[]), [.table])
        XCTAssertEqual(FolioCommand.ranked(query:"提取表格", recent:[]), [.table])
        XCTAssertEqual(FolioCommand.ranked(query:"勾选", recent:[]), [.forms])
        XCTAssertEqual(FolioCommand.ranked(query:"", recent:["forms","table"])[0], .forms)
        XCTAssertTrue(FolioCommand.ranked(query:"unfindable", recent:[]).isEmpty)
    }
    @MainActor func testUnavailableCommandsExplainContextAndDoNotRunOrEnterHistory() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root); store.bootstrap()
        XCTAssertNotNil(store.unavailableReason(.table)); store.performCommand(.table)
        XCTAssertTrue(store.recentCommands.isEmpty); XCTAssertFalse(store.commandWorkspace!.showTableExtraction)
        store.newNote(); XCTAssertNil(store.unavailableReason(.exportWord)); XCTAssertNotNil(store.unavailableReason(.rotate))
    }
    @MainActor func testPaletteUsesFocusedSplitAndRemembersCommandsAcrossSessions() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), a = store.newPDF(), b = store.newPDF(); store.select(a.id); store.openSplit(with:b.id); store.focus(b)
        store.performCommand(.rotate); XCTAssertEqual(b.document.page(at:0)!.rotation,90); XCTAssertEqual(a.document.page(at:0)!.rotation,0)
        XCTAssertEqual(WorkspaceStore(storage:root).recentCommands.first,"rotate")
        b.busy = true; XCTAssertNotNil(store.unavailableReason(.forms))
    }
    func testNativeTableTextAndRotationMapToVisibleCells() throws {
        let base = DocumentServicesTests().fixture().page(at: 0)!
        let lines = [RecognizedLine(text: "Apple", box: CGRect(x:0.15,y:0.7,width:0.2,height:0.06)), RecognizedLine(text:"Pear",box:CGRect(x:0.65,y:0.7,width:0.2,height:0.06)), RecognizedLine(text:"North",box:CGRect(x:0.15,y:0.2,width:0.2,height:0.06)), RecognizedLine(text:"South",box:CGRect(x:0.65,y:0.2,width:0.2,height:0.06))]
        let page = try DocumentServices.searchablePage(base, lines:lines)
        let table = try TableExtraction.extract(TableExtraction.pieces(page),x:[0,0.5,1],y:[0,0.5,1])
        XCTAssertEqual(table.rows,[["Apple","Pear"],["North","South"]])
        page.rotation = 90
        let turned = try TableExtraction.extract(TableExtraction.pieces(page),x:[0,0.5,1],y:[0,0.5,1])
        XCTAssertTrue(turned.rows.flatMap { $0 }.contains { $0.contains("Apple") || $0.contains("A") })
    }
    func testScannedTableRecognizesCharactersIntoSeparateCells() throws {
        let ctx = CGContext(data:nil,width:600,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(try gridImage(),in:CGRect(x:0,y:0,width:600,height:600))
        for (text,x,y) in [("Apple",100,430),("Pear",340,430),("North",100,190),("South",340,190)] {
            let string = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,32,nil)])
            ctx.textPosition = CGPoint(x:x,y:y); CTLineDraw(CTLineCreateWithAttributedString(string),ctx)
        }
        let pieces = try TableExtraction.recognize(ctx.makeImage()!,languages:["en-US"])
        let table = try TableExtraction.extract(pieces,x:[0.1,0.5,0.9],y:[0.1,0.5,0.9])
        XCTAssertEqual(table.rows,[["Apple","Pear"],["North","South"]])
    }

    @MainActor func testFilledFormAppearanceIsVisibleInFlattenedCopy() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let w = Workspace(storage: root); w.document = try forms()
        let field = PDFForms.fields(w.document)[0]
        try w.applyFormValues([field.id:"FILLED32"], from:w.revision)
        let flat = try PDFForms.flattened(w.document)
        let image = try DocumentServices.render(flat.page(at:0)!,maxDimension:2000)
        let recognized = try DocumentServices.recognize(image,languages:["en-US"]).map(\.text).joined(separator:" ")
        XCTAssertTrue(recognized.contains("FILLED32"))
    }

}
