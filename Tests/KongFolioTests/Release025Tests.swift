import XCTest
import PDFKit
@testable import KongFolio

final class Release025Tests: XCTestCase {
    func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("kf025-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    @MainActor func wait(_ queue:BatchQueue) async throws {
        let deadline=Date().addingTimeInterval(20)
        while queue.running && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(queue.running)
    }
    func testNewRecipeFieldsRoundTripAndOldRecipesStillDecode() throws {
        var recipe=WorkRecipe(name:"全部步骤",autoCrop:true,ocr:OCRSettings())
        recipe.splitSpreads=true;recipe.splitFraction=0.6;recipe.rightPageFirst=true;recipe.autoStraighten=true;recipe.compress = .strong
        XCTAssertEqual(try JSONDecoder().decode(WorkRecipe.self,from:JSONEncoder().encode(recipe)),recipe)
        let legacy=try JSONDecoder().decode(WorkRecipe.self,from:Data(#"{"name":"旧配方"}"#.utf8))
        XCTAssertFalse(legacy.splitSpreads);XCTAssertFalse(legacy.autoStraighten);XCTAssertNil(legacy.compress)
        XCTAssertTrue(recipe.summary.contains("跨页切分"));XCTAssertTrue(recipe.summary.contains("压缩"))
    }
    func testRecipeSplittingRemapsOutlineAfterOriginalPageRange() throws {
        let doc=DocumentServicesTests().fixture()
        ReadingServices.applyOutline([OutlineEntry(page:1,label:"第二页",depth:0),OutlineEntry(page:2,label:"第三页",depth:0)],to:doc)
        var recipe=WorkRecipe(name:"切分",pageRange:"2-3")
        recipe.splitSpreads=true;recipe.compress = .light
        let result=try BatchPipeline.process(doc.dataRepresentation()!,recipe:recipe,replacements:[],wordURL:nil)
        let output=PDFDocument(data:result.pdf!)!
        XCTAssertEqual(output.pageCount,4)
        XCTAssertEqual(ReadingServices.outline(output).map(\.page),[0,2])
        recipe.splitFraction=Double.nan
        XCTAssertThrowsError(try BatchPipeline.process(doc.dataRepresentation()!,recipe:recipe,replacements:[],wordURL:nil))
    }
    @MainActor func testQueueRetriesOnlyFailedItemsAndPersistsCompletedWork() async throws {
        let input=try folder(),output=try folder(),storage=try folder()
        defer { for url in [input,output,storage] { try? FileManager.default.removeItem(at:url) } }
        let a=input.appendingPathComponent("a.pdf"),b=input.appendingPathComponent("b.pdf")
        let bytes=DocumentServicesTests().fixture().dataRepresentation()!
        try bytes.write(to:a);try Data("broken".utf8).write(to:b)
        let queue=BatchQueue(storage:storage);queue.add([a,b])
        queue.start(recipe:WorkRecipe(name:"复制"),output:output,replacements:[]);try await wait(queue)
        XCTAssertEqual(queue.failedCount,1)
        let resultA=try Data(contentsOf:output.appendingPathComponent("a.pdf"))
        try bytes.write(to:b);queue.retryFailed();try await wait(queue)
        XCTAssertEqual(queue.failedCount,0);XCTAssertEqual(queue.items[0].attempts,1);XCTAssertEqual(queue.items[1].attempts,2)
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("a.pdf")),resultA)
        let restored=BatchQueue(storage:storage)
        XCTAssertEqual(restored.items.count,2);XCTAssertEqual(restored.completedCount,2)
        XCTAssertEqual(restored.plan?.recipe.id,queue.plan?.recipe.id)
    }
    @MainActor func testRestoredQueueUsesFrozenPlanAndVerifiesOutputs() async throws {
        let input=try folder(),output=try folder(),storage=try folder()
        defer { for url in [input,output,storage] { try? FileManager.default.removeItem(at:url) } }
        let source=input.appendingPathComponent("a.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to:source)
        let queue=BatchQueue(storage:storage);queue.add([source]);let recipe=WorkRecipe(name:"原配方")
        queue.start(recipe:recipe,output:output,replacements:[]);try await wait(queue)
        let restored=BatchQueue(storage:storage)
        XCTAssertEqual(restored.plan?.recipe,recipe)
        restored.start(recipe:recipe,output:output,replacements:[]);try await wait(restored)
        if case .skipped = restored.items[0].state {} else { XCTAssertTrue(false) }
        try Data("changed".utf8).write(to:output.appendingPathComponent("a.pdf"))
        restored.start(recipe:recipe,output:output,replacements:[]);try await wait(restored)
        XCTAssertEqual(restored.failedCount,1)
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("a.pdf")),Data("changed".utf8))
    }
    @MainActor func testInterruptedRunningStateRestoresAsWaiting() throws {
        let storage=try folder();defer { try? FileManager.default.removeItem(at:storage) }
        let item=BatchItem(url:storage.appendingPathComponent("input.pdf"),state:.running)
        let state=BatchQueue.Saved(items:[item],plan:BatchPlan(recipe:WorkRecipe(name:"继续"),output:storage.appendingPathComponent("out"),replacements:[]))
        try JSONEncoder().encode(state).write(to:storage.appendingPathComponent("BatchQueue.json"))
        let restored=BatchQueue(storage:storage)
        XCTAssertFalse(restored.running)
        if case .waiting = restored.items[0].state {} else { XCTAssertTrue(false) }
    }
    @MainActor func testCancellationReachesWorkerAndLeavesNoFinalOutput() async throws {
        let input=try folder(),output=try folder();defer { try? FileManager.default.removeItem(at:input);try? FileManager.default.removeItem(at:output) }
        let source=input.appendingPathComponent("book.pdf"),doc=PDFDocument()
        let fixture=DocumentServicesTests().fixture()
        for _ in 0..<40 { doc.insert(fixture.page(at:0)!.copy() as! PDFPage,at:doc.pageCount) }
        try doc.dataRepresentation()!.write(to:source)
        let queue=BatchQueue();queue.add([source]);var recipe=WorkRecipe(name:"纠偏");recipe.autoStraighten=true
        queue.start(recipe:recipe,output:output,replacements:[])
        let deadline=Date().addingTimeInterval(10)
        while queue.running && queue.fileProgress == 0 && Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(queue.running);queue.cancel();try await wait(queue)
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("book.pdf").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:output.path).count,0)
        if case .waiting = queue.items[0].state {} else { XCTAssertTrue(false) }
    }
    @MainActor func testQueueRefusesARecipeWithProcessingButNoOutput() {
        let queue=BatchQueue();queue.add([URL(fileURLWithPath:"/tmp/never-read.pdf")])
        let recipe=WorkRecipe(name:"无输出",autoCrop:true,writePDF:false)
        queue.start(recipe:recipe,output:URL(fileURLWithPath:"/tmp/never-write"),replacements:[])
        XCTAssertFalse(queue.running);XCTAssertTrue(queue.summary.contains("输出"))
    }
    @MainActor func testQueueRejectsCollidingNamesAndAnyInputFolderAsOutput() throws {
        let a=try folder(),b=try folder();defer { try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b) }
        let queue=BatchQueue();queue.add([a.appendingPathComponent("same.pdf"),b.appendingPathComponent("same.pdf"),b.appendingPathComponent("other.pdf")])
        XCTAssertEqual(queue.items.count,2)
        queue.start(recipe:WorkRecipe(name:"test"),output:b,replacements:[])
        XCTAssertFalse(queue.running);XCTAssertTrue(queue.summary.contains("相同"))
    }
    @MainActor func testDirectSaveSeedsOriginalAndRestoresAnOlderVersion() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("source.pdf"),w=Workspace(storage:directory)
        w.bootstrap();w.document=DocumentServicesTests().fixture();w.sourceURL=source
        try w.document.dataRepresentation()!.write(to:source)
        let annotation=PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.text,withProperties:nil)
        annotation.contents="new mark";w.document.page(at:0)!.addAnnotation(annotation);w.recordAnnotationsAdded([annotation])
        XCTAssertTrue(w.saveDirectly(askForDestination:false))
        let versions=try DocumentHistory.list(source:source,storage:directory)
        XCTAssertEqual(versions.count,2)
        let baseline=versions.last!
        let unsaved=PDFAnnotation(bounds:CGRect(x:40,y:10,width:20,height:20),forType:.text,withProperties:nil)
        unsaved.contents="unsaved mark";w.document.page(at:0)!.addAnnotation(unsaved);w.recordAnnotationsAdded([unsaved])
        XCTAssertTrue(w.restoreVersion(baseline))
        XCTAssertFalse(PDFDocument(url:source)!.page(at:0)!.annotations.contains { $0.contents == "new mark" })
        w.undo()
        XCTAssertTrue(w.document.page(at:0)!.annotations.contains { $0.contents == "new mark" })
        XCTAssertTrue(try DocumentHistory.list(source:source,storage:directory).contains { $0.label.contains("恢复历史前") })
    }
    @MainActor func testHistoryCoalescesAutosavesButKeepsBaselineAndManualVersions() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("source.pdf"),w=Workspace(storage:directory)
        w.document=DocumentServicesTests().fixture();try w.document.dataRepresentation()!.write(to:source)
        try DocumentHistory.protectExisting(source,storage:directory)
        let now=Date()
        for n in 1...4 {
            var a=try w.snapshot();a.reading?.bookmarks=[PageBookmark(page:0,label:"\(n)")]
            try DocumentHistory.record(a,source:source,storage:directory,automatic:true,now:now.addingTimeInterval(Double(n)))
        }
        let entries=try DocumentHistory.list(source:source,storage:directory)
        XCTAssertEqual(entries.count,2)
        XCTAssertEqual(try DocumentHistory.read(entries[0],source:source,storage:directory).reading?.bookmarks.first?.label,"4")
        var later=try w.snapshot();later.reading?.bookmarks=[PageBookmark(page:0,label:"after minute")]
        try DocumentHistory.record(later,source:source,storage:directory,automatic:true,now:now.addingTimeInterval(75))
        XCTAssertEqual(try DocumentHistory.list(source:source,storage:directory).count,3)
        var a=try w.snapshot();a.reading?.bookmarks=[PageBookmark(page:0,label:"manual")]
        try DocumentHistory.record(a,source:source,storage:directory,label:"手动",automatic:false)
        XCTAssertEqual(try DocumentHistory.list(source:source,storage:directory).count,4)
    }
    @MainActor func testHistoryIsBoundedAndRejectsTamperedPayload() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("a.pdf"),w=Workspace(storage:directory)
        w.document=DocumentServicesTests().fixture();try w.document.dataRepresentation()!.write(to:source)
        for n in 0..<15 {
            var archive=try w.snapshot();archive.reading?.bookmarks=[PageBookmark(page:0,label:"\(n)")]
            try DocumentHistory.record(archive,source:source,storage:directory,label:"手动",automatic:false)
        }
        let entries=try DocumentHistory.list(source:source,storage:directory)
        XCTAssertEqual(entries.count,10)
        let folder=DocumentHistory.folder(for:source,storage:directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path).filter { $0.hasSuffix(".kongfolio") }.count,10)
        try Data("corrupt".utf8).write(to:folder.appendingPathComponent(entries[0].id.uuidString+".kongfolio"))
        XCTAssertThrowsError(try DocumentHistory.read(entries[0],source:source,storage:directory))
    }
    @MainActor func testCorruptPredecessorIsReplacedBeforeAnotherSave() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("a.pdf"),w=Workspace(storage:directory)
        w.document=DocumentServicesTests().fixture();try w.document.dataRepresentation()!.write(to:source)
        try DocumentHistory.protectExisting(source,storage:directory)
        let first=try DocumentHistory.list(source:source,storage:directory)[0]
        let directoryURL=DocumentHistory.folder(for:source,storage:directory)
        try Data("bad".utf8).write(to:directoryURL.appendingPathComponent(first.id.uuidString+".kongfolio"))
        try DocumentHistory.protectExisting(source,storage:directory)
        let versions=try DocumentHistory.list(source:source,storage:directory)
        XCTAssertEqual(versions.count,2)
        XCTAssertEqual(try DocumentHistory.read(versions[0],source:source,storage:directory).pdf,try Data(contentsOf:source))
    }
    @MainActor func testProjectSavesAlsoHaveRestorableHistory() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("a.kongfolio"),w=Workspace(storage:directory)
        w.document=DocumentServicesTests().fixture();w.projectURL=source
        XCTAssertTrue(w.saveProject(background:false))
        w.rotate();XCTAssertTrue(w.saveProject(background:false))
        let versions=try DocumentHistory.list(source:source,storage:directory)
        XCTAssertEqual(versions.count,2)
        XCTAssertTrue(w.restoreVersion(versions.last!))
        XCTAssertEqual(try ProjectArchive.read(source).selection,0)
        XCTAssertEqual(PDFDocument(data:try ProjectArchive.read(source).pdf)!.page(at:0)!.rotation,0)
    }
    @MainActor func testHistoryFailureStopsOverwriteAndKeepsRecovery() throws {
        let directory=try folder();defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("a.pdf"),w=Workspace(storage:directory)
        w.bootstrap();w.document=DocumentServicesTests().fixture();w.sourceURL=source
        let bytes=w.document.dataRepresentation()!;try bytes.write(to:source)
        try Data("blocked".utf8).write(to:directory.appendingPathComponent("History"))
        w.rotate();XCTAssertFalse(w.saveDirectly(askForDestination:false))
        XCTAssertEqual(try Data(contentsOf:source),bytes)
        XCTAssertTrue(w.dirty);XCTAssertTrue(FileManager.default.fileExists(atPath:w.recoveryURL.path))
    }
}
