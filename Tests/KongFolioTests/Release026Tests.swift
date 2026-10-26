import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release026Tests: XCTestCase {
    func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("kf026-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func bytes() -> Data { DocumentServicesTests().fixture().dataRepresentation()! }
    func testAlignmentHandlesInsertDeleteAndModifiedPages() {
        let rows=PDFComparison.align(["a","b","c","d"],["x","a","B","c"])
        XCTAssertEqual(rows.map { $0.0 },[nil,0,1,2,3])
        XCTAssertEqual(rows.map { $0.1 },[0,1,2,3,nil])
        let repeated=PDFComparison.align(["blank","a","blank"],["blank","a","blank","z"])
        XCTAssertEqual(repeated.map { $0.0 },[0,1,2,nil])
        XCTAssertEqual(repeated.map { $0.1 },[0,1,2,3])
    }
    func testAlignmentScalesToTenThousandPages() {
        let values=(0..<10000).map(String.init)
        var changed=values;changed.insert("insert",at:5000)
        let rows=PDFComparison.align(values,changed)
        XCTAssertEqual(rows.count,10001)
        XCTAssertNil(rows[5000].0);XCTAssertEqual(rows[5000].1,5000)
        XCTAssertEqual(rows.last?.0,9999);XCTAssertEqual(rows.last?.1,10000)
    }
    @MainActor func testNativeSidebarSelectionKeepsFocusAndRejectsEmptyOrInvalidPages() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let workspace=Workspace(storage:directory);workspace.bootstrap();workspace.document=PDFDocument(data:bytes())!
        workspace.selectSidebarPages([0,2]);XCTAssertEqual(workspace.selection,2);XCTAssertEqual(workspace.selectedPages,[0,2])
        workspace.selectSidebarPages([0]);XCTAssertEqual(workspace.selection,0)
        workspace.selectSidebarPages([]);XCTAssertEqual(workspace.selectedPages,[0])
        workspace.selectSidebarPages([999]);XCTAssertEqual(workspace.selectedPages,[0])
    }
    func testComparisonDetectsRotationCropAndAnnotations() throws {
        let original=bytes(),after=PDFDocument(data:original)!
        after.page(at:0)!.rotation=90
        after.page(at:1)!.setBounds(CGRect(x:20,y:20,width:250,height:300),for:.cropBox)
        let mark=PDFAnnotation(bounds:CGRect(x:20,y:20,width:40,height:40),forType:.text,withProperties:nil);mark.contents="new note"
        after.page(at:2)!.addAnnotation(mark)
        let rows=try PDFComparison.compare(original,after.dataRepresentation()!)
        XCTAssertEqual(rows.count,3)
        XCTAssertTrue(rows[0].changes.contains("旋转"))
        XCTAssertTrue(rows[1].changes.contains("裁边 / 尺寸"))
        XCTAssertTrue(rows[2].changes.contains("批注"))
        XCTAssertEqual(rows.map(\.before),[0,1,2]);XCTAssertEqual(rows.map(\.after),[0,1,2])
    }
    func testComparisonDetectsAddedPageWithoutShiftingEveryFollowingPage() throws {
        let original=bytes(),after=PDFDocument(data:original)!
        let blank=PDFPage();blank.setBounds(CGRect(x:0,y:0,width:300,height:400),for:.mediaBox)
        after.insert(blank,at:1)
        let rows=try PDFComparison.compare(original,after.dataRepresentation()!)
        XCTAssertEqual(rows.count,4)
        XCTAssertEqual(rows.filter(\.changed).count,1)
        XCTAssertEqual(rows[1].changes,["新增页"]);XCTAssertNil(rows[1].before)
        XCTAssertEqual(rows[2].before,1);XCTAssertEqual(rows[2].after,2)
    }
    func testComparisonUnchangedAndInvalidPDF() throws {
        let data=bytes()
        XCTAssertTrue(try PDFComparison.compare(data,data).allSatisfy { !$0.changed })
        XCTAssertThrowsError(try PDFComparison.compare(Data(),data))
    }
    func testComparisonDoesNotRemoveSourceAnnotations() throws {
        let doc=PDFDocument(data:bytes())!,page=doc.page(at:0)!
        let note=PDFAnnotation(bounds:CGRect(x:10,y:10,width:30,height:30),forType:.text,withProperties:nil);note.contents="retain me"
        page.addAnnotation(note)
        let signature=try PDFComparison.signature(page)
        XCTAssertTrue(signature.annotations.contains("retain me"))
        XCTAssertTrue(page.annotations.contains { $0.contents=="retain me" })
        XCTAssertEqual(page.rotation,0)
    }
    func testRecipeTrialDoesNotModifyInputOrWriteOutputs() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("sample.pdf"),data=bytes();try data.write(to:source)
        var recipe=WorkRecipe(name:"试跑",word:WordExportOptions(),pageRange:"2-3",splitChapters:true)
        recipe.splitSpreads=true
        let result=try RecipeTrial.run(source:source,range:"2-3",recipe:recipe,replacements:[])
        XCTAssertEqual(PDFDocument(data:result.before)?.pageCount,2)
        XCTAssertEqual(PDFDocument(data:result.after)?.pageCount,4)
        XCTAssertEqual(result.rows.map(\.before),[0,0,1,1])
        XCTAssertEqual(try Data(contentsOf:source),data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),["sample.pdf"])
        XCTAssertTrue(PDFDocument(data:result.before)!.page(at:0)!.annotations.count>=2)
    }
    func testTrialRejectsMoreThanSixPagesOrAnEmptyRange() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("sample.pdf"),doc=DocumentServicesTests().fixture()
        for _ in 0..<4 { doc.insert(doc.page(at:0)!.copy() as! PDFPage,at:doc.pageCount) }
        try doc.dataRepresentation()!.write(to:source)
        XCTAssertThrowsError(try RecipeTrial.run(source:source,range:"1-7",recipe:WorkRecipe(name:"试跑"),replacements:[]))
        XCTAssertThrowsError(try RecipeTrial.run(source:source,range:"999",recipe:WorkRecipe(name:"试跑"),replacements:[]))
    }
    func testSplitThenCropNeverReintroducesTheOtherHalf() throws {
        let data=bytes(),original=PDFDocument(data:data)!
        var recipe=WorkRecipe(name:"切分裁边",autoCrop:true);recipe.splitSpreads=true
        let result=try BatchPipeline.process(data,recipe:recipe,replacements:[],wordURL:nil)
        let output=PDFDocument(data:result.pdf!)!
        for index in 0..<output.pageCount {
            let expected=ScanProcessing.splitBoxes(original.page(at:index/2)!,fraction:0.5)[index%2]
            let actual=output.page(at:index)!.bounds(for:.cropBox)
            XCTAssertTrue(expected.insetBy(dx:-0.01,dy:-0.01).contains(actual))
        }
    }
    func testCheckpointSurvivesInterruptionAndResumesOnlyRemainingPages() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let data=bytes();var settings=OCRSettings();settings.ignoresTextLayer=true
        let recipe=WorkRecipe(name:"OCR",ocr:settings)
        var firstCalls=0,interrupted=false
        do {
            _=try BatchPipeline.process(data,recipe:recipe,replacements:[],wordURL:nil,checkpointRoot:directory,recognize:{ _,_ in
                firstCalls += 1;if firstCalls==2 { throw CancellationError() }
                return [RecognizedLine(text:"checkpoint",box:CGRect(x:0.1,y:0.2,width:0.5,height:0.1))]
            })
        } catch is CancellationError { interrupted=true }
        XCTAssertTrue(interrupted)
        let cache=try OCRPageCache(root:directory,source:data,recipe:recipe)
        let cached=try XCTUnwrap(cache.read(0));XCTAssertNil(cache.read(1))
        let cachedDocument=try XCTUnwrap(PDFDocument(data:cached.pdf))
        XCTAssertTrue(cachedDocument.string?.contains("checkpoint") ?? false, "Cached OCR text: \(String(reflecting: cachedDocument.string))")
        var resumedCalls=0
        let result=try BatchPipeline.process(data,recipe:recipe,replacements:[],wordURL:nil,checkpointRoot:directory,recognize:{ _,_ in resumedCalls += 1;return [] })
        XCTAssertEqual(resumedCalls,2);XCTAssertEqual(result.resumed,1)
        let restored=try XCTUnwrap(PDFDocument(data:try XCTUnwrap(result.pdf)))
        XCTAssertEqual(result.recognized,3);XCTAssertEqual(restored.pageCount,3)
        withExtendedLifetime(restored) {
            XCTAssertTrue(restored.page(at:0)?.string?.contains("checkpoint") ?? false, "Restored OCR text: \(String(reflecting: restored.page(at:0)?.string))")
        }
    }
    func testCheckpointContextInvalidatesForSourceAndRecipeChanges() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let data=bytes(),recipe=WorkRecipe(name:"OCR",ocr:OCRSettings()),doc=PDFDocument(data:data)!
        let cache=try OCRPageCache(root:directory,source:data,recipe:recipe)
        try cache.write(index:0,page:doc.page(at:0)!,lines:[],recognized:true)
        var changed=recipe;changed.splitSpreads=true
        XCTAssertNil(try OCRPageCache(root:directory,source:data,recipe:changed).read(0))
        XCTAssertNil(try OCRPageCache(root:directory,source:data+Data([0]),recipe:recipe).read(0))
        XCTAssertNotNil(cache.read(0))
    }
    func testCorruptCheckpointIsRecomputed() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let data=bytes(),doc=PDFDocument(data:data)!,recipe=WorkRecipe(name:"OCR",ocr:OCRSettings())
        let cache=try OCRPageCache(root:directory,source:data,recipe:recipe)
        try cache.write(index:0,page:doc.page(at:0)!,lines:nil,recognized:false)
        try Data("tampered".utf8).write(to:cache.directory.appendingPathComponent("0.json"))
        XCTAssertNil(cache.read(0))
        _=try BatchPipeline.process(data,recipe:recipe,replacements:[],wordURL:nil,checkpointRoot:directory,recognize:{ _,_ in [] })
        XCTAssertNotNil(cache.read(0))
    }
    func testCheckpointWriteFailureStopsOutput() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let path=directory.appendingPathComponent("not-a-folder");try Data([1]).write(to:path)
        XCTAssertThrowsError(try BatchPipeline.process(bytes(),recipe:WorkRecipe(name:"OCR",ocr:OCRSettings()),replacements:[],wordURL:nil,checkpointRoot:path,recognize:{ _,_ in [] }))
    }
    func testCheckpointRejectsValidJSONWithTamperedPayload() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let data=bytes(),doc=PDFDocument(data:data)!,recipe=WorkRecipe(name:"OCR",ocr:OCRSettings())
        let cache=try OCRPageCache(root:directory,source:data,recipe:recipe)
        try cache.write(index:0,page:doc.page(at:0)!,lines:nil,recognized:false)
        let url=cache.directory.appendingPathComponent("0.json")
        var envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        var payload=try JSONSerialization.jsonObject(with:Data(base64Encoded:envelope["payload"] as! String)!) as! [String:Any]
        payload["recognized"]=true
        envelope["payload"]=try JSONSerialization.data(withJSONObject:payload).base64EncodedString()
        try JSONSerialization.data(withJSONObject:envelope).write(to:url)
        XCTAssertNil(cache.read(0))
    }
    @MainActor func testQueueCommitRemovesItsPageCache() async throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let input=directory.appendingPathComponent("input.pdf"),output=directory.appendingPathComponent("out"),storage=directory.appendingPathComponent("storage")
        let data=bytes();try data.write(to:input)
        let recipe=WorkRecipe(name:"OCR",ocr:OCRSettings()),queue=BatchQueue(storage:storage);queue.add([input])
        let cacheRoot=storage.appendingPathComponent("BatchPages").appendingPathComponent(queue.items[0].id.uuidString)
        let cache=try OCRPageCache(root:cacheRoot,source:data,recipe:recipe),doc=PDFDocument(data:data)!
        for index in 0..<doc.pageCount { try cache.write(index:index,page:doc.page(at:index)!,lines:nil,recognized:false) }
        queue.start(recipe:recipe,output:output,replacements:[])
        try await Release025Tests().wait(queue)
        XCTAssertEqual(queue.failedCount,0);XCTAssertEqual(queue.completedCount,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:cacheRoot.path))
        if case .done(let note)=queue.items[0].state { XCTAssertTrue(note.contains("复用 3 页")) } else { XCTAssertTrue(false) }
    }
    @MainActor func testRestoreSinglePagePreservesOtherWorkAndCanUndo() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("book.pdf"),workspace=Workspace(storage:directory)
        workspace.bootstrap();workspace.document=PDFDocument(data:bytes())!;workspace.sourceURL=source;workspace.alignMeta()
        workspace.outlineEntries=[OutlineEntry(page:1,label:"当前目录",depth:0)]
        XCTAssertTrue(workspace.saveDirectly(askForDestination:false))
        let baseline=try DocumentHistory.list(source:source,storage:directory)[0]
        workspace.document.page(at:0)!.rotation=90
        let note=PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.text,withProperties:nil);note.contents="unsaved"
        workspace.document.page(at:1)!.addAnnotation(note)
        workspace.edited()
        XCTAssertTrue(workspace.restoreHistoryPage(baseline,page:0,replacing:0))
        XCTAssertEqual(workspace.document.page(at:0)!.rotation,0)
        XCTAssertTrue(workspace.document.page(at:1)!.annotations.contains { $0.contents=="unsaved" })
        XCTAssertEqual(workspace.outlineEntries.map(\.label),["当前目录"])
        XCTAssertEqual(workspace.count,3)
        workspace.undo()
        XCTAssertEqual(workspace.document.page(at:0)!.rotation,90)
        XCTAssertTrue(workspace.document.page(at:1)!.annotations.contains { $0.contents=="unsaved" })
        XCTAssertTrue(try DocumentHistory.list(source:source,storage:directory).contains { $0.label=="恢复单页前的当前工作" })
    }
    @MainActor func testRestoreSinglePageRejectsInvalidIndexesWithoutMutation() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("book.pdf"),workspace=Workspace(storage:directory)
        workspace.bootstrap();workspace.document=PDFDocument(data:bytes())!;workspace.sourceURL=source
        XCTAssertTrue(workspace.saveDirectly(askForDestination:false))
        let baseline=try DocumentHistory.list(source:source,storage:directory)[0],previous=try workspace.pdfData()
        XCTAssertFalse(workspace.restoreHistoryPage(baseline,page:999,replacing:0))
        XCTAssertFalse(workspace.restoreHistoryPage(baseline,page:0,replacing:999))
        XCTAssertEqual(try workspace.pdfData(),previous)
    }
}
