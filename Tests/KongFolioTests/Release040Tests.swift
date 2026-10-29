import XCTest
import PDFKit
import AppKit
@testable import KongFolio

final class Release040Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func pdf(_ root:URL,name:String = "book.pdf",pages:Int = 4) throws -> URL { try Release038Tests().pdf(root,name:name,pages:pages) }
    @MainActor func open(_ file:URL,storage:URL) throws -> Workspace { try Release038Tests().open(file,storage:storage) }
    @MainActor func settle(_ controller:ResearchController) async throws {
        let limit = Date().addingTimeInterval(15)
        while controller.busy, Date() < limit { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertFalse(controller.busy)
    }
    func scans() throws -> Data {
        let doc = PDFDocument()
        for x in [30,210] {
            let context = CGContext(data:nil,width:400,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:400,height:600))
            context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:x,y:100,width:80,height:260))
            let image = NSImage(cgImage:context.makeImage()!,size:NSSize(width:400,height:600)); doc.insert(PDFPage(image:image)!,at:doc.pageCount)
        }
        return try XCTUnwrap(doc.dataRepresentation())
    }
    @MainActor func testCompleteSnapshotYieldsToReaderAndKeepsAllPages() async throws {
        let root = try root(), file = try pdf(root,pages:300), w = try open(file,storage:root)
        w.document.documentAttributes = [PDFDocumentAttribute.titleAttribute:"保留书名"]
        w.document.page(at:299)?.rotation = 90; w.changed(); w.cachedPDF = nil
        var beats = 0
        let timer = Task { @MainActor in while !Task.isCancelled { beats += 1; do { try await Task.sleep(nanoseconds:2_000_000) } catch { return } } }
        defer { timer.cancel() }
        let snapshot = try await w.snapshotForBackgroundSave(), copy = try XCTUnwrap(PDFDocument(data:snapshot.pdf))
        XCTAssertEqual(copy.pageCount,300); XCTAssertEqual(copy.page(at:299)?.rotation,90); XCTAssertTrue(beats > 10)
        XCTAssertEqual(copy.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,"保留书名")
    }
    @MainActor func testEditDuringPreparationCannotCommitOldSnapshot() async throws {
        let root = try root(), file = try pdf(root,pages:120), w = try open(file,storage:root)
        w.changed(); w.cachedPDF = nil
        let capture = Task { try await w.snapshotForBackgroundSave() }
        while w.saveProgress == 0 { try await Task.sleep(nanoseconds:1_000_000) }
        _ = Release038Tests().annotate(w,text:"准备期间的新修改")
        do { _ = try await capture.value; XCTAssertTrue(false,"旧快照应中止") } catch {}
        let latest = try await w.snapshotForBackgroundSave()
        XCTAssertEqual(PDFDocument(data:latest.pdf)?.page(at:0)?.annotations.first?.contents,"准备期间的新修改")
    }
    @MainActor func testCancellingPreparationLeavesOriginalAndDirtyState() async throws {
        let root = try root(), file = try pdf(root,pages:120), before = try Data(contentsOf:file), w = try open(file,storage:root)
        w.changed(); w.cachedPDF = nil
        let save = Task { await w.saveInBackground() }
        while w.saveProgress == 0 { try await Task.sleep(nanoseconds:1_000_000) }
        save.cancel(); let saved = await save.value
        XCTAssertFalse(saved); XCTAssertTrue(w.dirty); XCTAssertEqual(try Data(contentsOf:file),before); XCTAssertFalse(w.captureInProgress)
    }
    @MainActor func testPreparingPrivateSnapshotCannotUnloadTheDocument() throws {
        let root = try root(), w = try open(pdf(root),storage:root)
        XCTAssertTrue(w.canUnload); w.preparingSnapshot = true; XCTAssertFalse(w.canUnload); w.preparingSnapshot = false; w.captureInProgress = true; XCTAssertFalse(w.canUnload)
    }
    func testMemoryHysteresisDoesNotOscillateAtBudgetBoundary() {
        XCTAssertTrue(RuntimeMemory.constrained(resident:800,budget:768,wasConstrained:false))
        XCTAssertTrue(RuntimeMemory.constrained(resident:700,budget:768,wasConstrained:true))
        XCTAssertFalse(RuntimeMemory.constrained(resident:500,budget:768,wasConstrained:true))
        XCTAssertTrue(RuntimeMemory.residentMB() > 0)
    }
    @MainActor func testRuntimeMemoryLowersFutureTasksAndProtectsDirtyBook() async throws {
        let root = try root(), store = WorkspaceStore(storage:root); store.bootstrap()
        let file = try pdf(root); store.activeWorkspace!.load([file],prepared:.documents([try Data(contentsOf:file)])); store.activeWorkspace!.dirty = true
        store.sampleRuntimeMemory(resident:1200); XCTAssertTrue(store.constrainedMemory); XCTAssertEqual(store.documentTasks.maximumActive,1); XCTAssertTrue(store.activeWorkspace!.count > 0)
        store.sampleRuntimeMemory(resident:100); XCTAssertFalse(store.constrainedMemory); XCTAssertEqual(store.documentTasks.maximumActive,2)
        await ImportLimiter.shared.setMaximum(2)
    }
    func testDynamicImportLimitRespectsCancellation() async throws {
        let limiter = ImportLimiter(); await limiter.setMaximum(1); try await limiter.acquire()
        let blocked = Task { try await limiter.acquire() }; blocked.cancel()
        do { try await blocked.value; XCTAssertTrue(false) } catch {}
        let count = await limiter.running; XCTAssertEqual(count,1); await limiter.release()
        await limiter.setMaximum(2); try await limiter.acquire(); try await limiter.acquire(); await limiter.release(); await limiter.release()
    }
    func testOCRBudgetWaitCanBeCancelledWithoutLeakingSlot() async throws {
        let gate = OCRResourceGate(maximum:1); try gate.acquire()
        let task = Task.detached { try gate.acquire() }; task.cancel()
        do { try await task.value; XCTAssertTrue(false) } catch {}
        XCTAssertEqual(gate.running,1); gate.release(); XCTAssertEqual(gate.running,0)
    }
    func testInterruptedStartupRequiresReviewAndTracksRepeatedOpening() throws {
        let guarder = StartupProtection(storage:try root()); _ = try guarder.begin(); guarder.opening("/problem.pdf")
        let first = try guarder.begin(); XCTAssertTrue(first.reviewRequired); XCTAssertEqual(first.interrupted["/problem.pdf"],1)
        guarder.opening("/problem.pdf"); let next = try guarder.begin(); XCTAssertEqual(next.interrupted["/problem.pdf"],2)
        try guarder.finishReview(excluding:["bad"]); guarder.clean(); let normal = try guarder.begin(); XCTAssertFalse(normal.reviewRequired); XCTAssertTrue(normal.excludedSlots.contains("bad"))
    }
    @MainActor func testSafeStartupDoesNotLoadRecoveryUntilUserSelectsBook() throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root)
        w.bookmarkName = "安全恢复书签"; w.addBookmark(); XCTAssertTrue(w.flushRecovery())
        let entries = [SessionEntry(slot:"",kind:.recovery)]
        try JSONEncoder().encode(Session(entries:entries,selected:"")).write(to:root.appendingPathComponent("Session.json"))
        _ = try StartupProtection(storage:root).begin()
        let store = WorkspaceStore(storage:root); store.startupSafetyEnabled = true; store.bootstrap()
        XCTAssertTrue(store.showStartupReview); XCTAssertEqual(store.activeWorkspace?.count,0); XCTAssertEqual(store.startupEntries.count,1)
        XCTAssertTrue(store.activeWorkspace?.slot != "")
        try store.restoreStartup(entries[0]); XCTAssertEqual(store.activeWorkspace?.bookmarks.first?.label,"安全恢复书签"); XCTAssertTrue(store.startupEntries.isEmpty)
    }
    @MainActor func testSkippingStartupKeepsRecoveryButDoesNotReopenItNextTime() throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root); w.dirty = true; XCTAssertTrue(w.flushRecovery())
        _ = try StartupProtection(storage:root).begin()
        let store = WorkspaceStore(storage:root); store.startupSafetyEnabled = true; store.bootstrap(); let recovery = w.recoveryURL
        try store.skipStartupEntries(); XCTAssertTrue(FileManager.default.fileExists(atPath:recovery.path))
        StartupProtection(storage:root).clean(); let again = WorkspaceStore(storage:root); again.startupSafetyEnabled = true; again.bootstrap()
        XCTAssertEqual(again.activeWorkspace?.count,0); XCTAssertFalse(again.showStartupReview)
    }
    func testCorruptStartupMarkerIsPreservedAndTriggersReview() throws {
        let root = try root(), protection = StartupProtection(storage:root), bad = Data("damaged".utf8); try bad.write(to:protection.url)
        let state = try protection.begin(); XCTAssertTrue(state.reviewRequired)
        let copies = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.contains("damaged-") }
        XCTAssertEqual(copies.count,1); XCTAssertEqual(try Data(contentsOf:copies[0]),bad)
    }
    func testPageEditorRoundTripKeepsRomanPrefixesAndUnnumberedSegments() throws {
        let segments = [PrintedPageSegment(start:0,end:1,style:.none),PrintedPageSegment(start:2,end:4,first:1,prefix:"序-",style:.roman)]
        let rows = segments.map(PrintedPageRow.init); try PrintedPageSegment.validate(rows.map(\.segment),count:5)
        XCTAssertEqual(rows[1].preview,"序-i → 序-iii"); XCTAssertEqual(rows.map(\.segment),segments)
    }
    func testInsertionAtChineseCaretKeepsSelectedTextAndRealNoteDefinition() throws {
        let source = "第一段\n\n这里摘录原文。", ns = source as NSString, range = ns.range(of:"摘录原文")
        let edit = AcademicInsertion.footnote.edit(source,selection:range), result = ns.replacingCharacters(in:edit.range,with:edit.replacement)
        XCTAssertTrue(result.contains("摘录原文[^1]。")); XCTAssertEqual(try AcademicMarkup.parse(result).footnotes["1"],"请填写注释内容")
    }
    func testInsertionNeverReusesExistingFootnoteNumber() throws {
        let source = "已有[^1]\n\n[^1]: 原注", edit = AcademicInsertion.footnote.edit(source,selection:NSRange(location:0,length:0))
        let result = (source as NSString).replacingCharacters(in:edit.range,with:edit.replacement)
        XCTAssertEqual(try AcademicMarkup.parse(result).footnotes.count,2); XCTAssertTrue(result.hasPrefix("[^2]"))
    }
    @MainActor func testAcademicPreviewContainsActualDocxNotesAndTable() async throws {
        let root = try root(), controller = ResearchController(); controller.academicStorage = root
        controller.academicText = "# 研究稿\n\n正文[^1]\n\n| 年 | 期 |\n| --- | --- |\n| 1882 | 12 |\n\n[^1]: 真实注释"
        controller.previewAcademic(); try await settle(controller)
        let file = try XCTUnwrap(controller.academicPreviewURL), xml = try WordExportTests().unzip(["-p",file.path,"word/document.xml"])
        XCTAssertTrue(xml.contains("footnoteReference")); XCTAssertTrue(xml.contains("<w:tbl>")); XCTAssertTrue(try WordExportTests().unzip(["-p",file.path,"word/footnotes.xml"]).contains("真实注释"))
    }
    @MainActor func testResearchCancelReachesWorkerBeforeApplyingResult() async throws {
        let controller = ResearchController(); controller.academicText = "原稿"
        controller.perform { let text = try await controller.background { () throws -> String in for _ in 0..<100 { try Task.checkCancellation(); Thread.sleep(forTimeInterval:0.002) }; return "迟到的结果" }; controller.academicText = text; return "完成" }
        try await Task.sleep(nanoseconds:10_000_000); controller.cancel(); try await settle(controller)
        XCTAssertEqual(controller.academicText,"原稿"); XCTAssertTrue(controller.message.contains("取消"))
    }
    func testSourceFingerprintIgnoresAnnotationsButDetectsScanRotation() throws {
        let original = try scans(), before = try ResearchSourceBinding.make(original,digest:"a"), doc = PDFDocument(data:original)!
        doc.page(at:0)?.addAnnotation(PDFAnnotation(bounds:CGRect(x:10,y:10,width:50,height:20),forType:.text,withProperties:nil))
        let marked = try XCTUnwrap(doc.dataRepresentation()), after = try ResearchSourceBinding.make(marked,digest:"b")
        XCTAssertTrue(before.samePages(after))
        doc.page(at:0)?.rotation = 90; let rotated = try ResearchSourceBinding.make(doc.dataRepresentation()!,digest:"c"); XCTAssertFalse(before.samePages(rotated))
    }
    func testSourceFingerprintDetectsScanReorderingAndMissingPages() throws {
        let bytes = try scans(), source = try ResearchSourceBinding.make(bytes,digest:"a"), doc = PDFDocument(data:bytes)!
        let first = doc.page(at:0)!; doc.removePage(at:0); doc.insert(first,at:1)
        XCTAssertFalse(source.samePages(try ResearchSourceBinding.make(doc.dataRepresentation()!,digest:"b")))
        doc.removePage(at:1); XCTAssertFalse(source.samePages(try ResearchSourceBinding.make(doc.dataRepresentation()!,digest:"c")))
    }
    @MainActor func testSourceChangeDisablesOldLabelsWithoutDeletingThem() async throws {
        let store = ResearchStore(storage:try root()), bytes = try scans(), binding = try ResearchSourceBinding.make(bytes,digest:"old")
        try store.update { $0.labels["/book.pdf"] = [PrintedPageSegment(start:0,end:1,first:10)]; $0.bindings = ["/book.pdf":binding] }
        let doc = PDFDocument(data:bytes)!; doc.page(at:0)?.rotation = 90
        await store.validateSource(path:"/book.pdf",bytes:doc.dataRepresentation()!,digest:"new")
        XCTAssertNotNil(store.warning(path:"/book.pdf")); XCTAssertNil(store.label(path:"/book.pdf",page:0)); XCTAssertEqual(store.state.labels["/book.pdf"]?.first?.first,10)
    }
    @MainActor func testAnnotationOnlySourceChangeUpdatesBindingSafely() async throws {
        let store = ResearchStore(storage:try root()), bytes = try scans(), binding = try ResearchSourceBinding.make(bytes,digest:"old")
        try store.update { $0.labels["/book.pdf"] = [PrintedPageSegment(start:0,end:1)]; $0.bindings = ["/book.pdf":binding] }
        await store.validateSource(path:"/book.pdf",bytes:bytes,digest:"new")
        XCTAssertNil(store.warning(path:"/book.pdf")); XCTAssertEqual(store.binding(path:"/book.pdf")?.digest,"new"); XCTAssertEqual(store.label(path:"/book.pdf",page:0),"1")
    }
    @MainActor func testExternalReplacementWhileReaderOpenRaisesWarning() async throws {
        let root = try root(), file = try pdf(root), store = WorkspaceStore(storage:root); store.bootstrap(); store.activeWorkspace!.load([file],prepared:.documents([try Data(contentsOf:file)]))
        try Data("externally replaced".utf8).write(to:file); store.checkOpenSourceChanges()
        let end = Date().addingTimeInterval(5); while store.research.warning(path:file.path) == nil, Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertNotNil(store.research.warning(path:file.path)); XCTAssertTrue(store.activeWorkspace!.count > 0)
    }
    func testCorrectionConflictReportFindsAmbiguityAndNonCascadingChain() {
        let messages = CorrectionConflicts.messages([ReplacementRule(from:"甲",to:"乙"),ReplacementRule(from:"甲",to:"丙"),ReplacementRule(from:"乙",to:"丁")])
        XCTAssertTrue(messages.contains { $0.contains("多个替换结果") }); XCTAssertTrue(messages.contains { $0.contains("不会串联") })
    }
    func testReadingRulerPersistsPerBookAndClampsMovement() throws {
        let root = try root(); var ruler = ReadingRuler(enabled:true,direction:.vertical,position:0.9,thickness:0.1,opacity:0.3)
        ruler.move(0.5); XCTAssertEqual(ruler.position,1); try ruler.save(path:"/book.pdf",storage:root)
        XCTAssertEqual(ReadingRuler.read(path:"/book.pdf",storage:root),ruler); XCTAssertFalse(ReadingRuler.read(path:"/other.pdf",storage:root).enabled)
        ruler.opacity = .nan; XCTAssertThrowsError(try ruler.save(path:"/book.pdf",storage:root))
    }
    func note(key:String,page:Int) -> ResearchAnnotation { ResearchAnnotation(key:key,path:"/book.pdf",page:page,quote:"摘录\(page)",comment:"原批注",kind:"高亮",color:"黄",tags:[],modified:Date()) }
    func testTopicDeduplicatesOrdersAndExportsEachActualSourcePage() throws {
        var topic = ResearchTopic(name:"近代思想"); let a = note(key:"a",page:2), b = note(key:"b",page:10)
        topic.add([a,b,a]); XCTAssertEqual(topic.items.count,2); topic.move(topic.items[1].id,delta:-1); topic.items[0].reflection = "自己的分析"
        let text = try topic.markdown(template:CitationTemplate()) { _,page in ("作者","书名","1882",String(page+1)) }
        XCTAssertTrue(text.contains("第11页")); XCTAssertTrue(text.contains("第3页")); XCTAssertTrue(text.contains("自己的分析")); XCTAssertTrue(text.contains("kongfolio://"))
        XCTAssertEqual(topic.items.first?.annotation.key,"b")
    }
    @MainActor func testTopicsAndSourceBindingsAreBackwardCompatibleAndSurviveReopen() throws {
        let root = try root(), store = ResearchStore(storage:root)
        try store.update { $0.topics = [ResearchTopic(name:"专题")]; $0.bindings = ["/a.pdf":ResearchSourceBinding(digest:"x",pages:["p"])] }
        let reopened = ResearchStore(storage:root); XCTAssertEqual(reopened.state.topics?.first?.name,"专题"); XCTAssertEqual(reopened.binding(path:"/a.pdf")?.digest,"x")
        let old = Data("{\"version\":1,\"groups\":[],\"labels\":{},\"periodicals\":{},\"dictionary\":[],\"filters\":[],\"annotations\":[],\"editions\":[],\"citation\":{\"text\":\"旧模板\"}}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ResearchStore.State.self,from:old).topics)
    }
    @MainActor func testSelectedBackupRestoresOnlyChosenBookAndItsDraftAndRuler() throws {
        let root = try root(), a = try pdf(root,name:"a.pdf"), b = try pdf(root,name:"b.pdf"), library = BookLibrary(storage:root); try library.add([a,b])
        let path = library.books.first { $0.title == "a" }?.path ?? library.books[0].path
        try AcademicDraftStore.write(.init(text:"所选书的草稿",source:path,digest:nil,modified:Date()),storage:root)
        try ReadingRuler(enabled:true).save(path:path,storage:root)
        var state = ResearchStore.State(); state.groups = [ReadingGroup(name:"组",books:library.books.enumerated().map { i,book in .init(path:book.path,position:ViewPosition(selection:0),layout:.continuous,partner:1-i) })]
        let full = try ResearchBackup.capture(storage:root,catalog:library.catalog,research:state,progress:[:],includeOriginals:true)
        let selected = try full.selecting([path],includeShared:false); XCTAssertEqual(selected.catalog.books.count,1); XCTAssertNil(selected.research.groups[0].books[0].partner)
        let result = try selected.restore(in:root), support = result.root.appendingPathComponent("AppData"), newPath = BookLibrary(storage:support).books[0].path
        XCTAssertEqual(try AcademicDraftStore.read(source:newPath,storage:support)?.text,"所选书的草稿")
        XCTAssertTrue(ReadingRuler.read(path:newPath,storage:support).enabled)
    }
    @MainActor func testBackupSelectionKeepsSharedImageResourcesWithoutOtherNotes() throws {
        let root = try root(), file = try pdf(root), library = BookLibrary(storage:root); try library.add([file])
        let image = ResearchBackup.Asset(path:"NoteAssets/image.png",bytes:Data([1,2]),digest:OCRPageCache.digest(Data([1,2])))
        let note = ResearchBackup.Asset(path:"Notes/unselected.json",bytes:Data("{}".utf8),digest:OCRPageCache.digest(Data("{}".utf8)))
        let backup = ResearchBackup(catalog:library.catalog,research:ResearchStore.State(),originals:[:],companions:[image,note],progress:[:])
        let selected = try backup.selecting([library.books[0].path],includeShared:false)
        XCTAssertEqual(selected.companions.map(\.path),[image.path]); XCTAssertThrowsError(try backup.selecting([],includeShared:false))
    }
    @MainActor func testTrialProducesStructuredReportAndLeavesOriginalUntouched() async throws {
        let root = try root(), file = try pdf(root,pages:4), original = try Data(contentsOf:file), store = WorkspaceStore(storage:root); store.bootstrap(); store.activeWorkspace!.load([file],prepared:.documents([original]))
        let controller = ResearchController(); controller.trial(store,recipe:WorkRecipe(name:"仅 PDF"),range:"2-3"); try await settle(controller)
        let report = try XCTUnwrap(controller.trialReport); XCTAssertEqual(report.inputPages,2); XCTAssertEqual(report.outputPages,2); XCTAssertTrue(report.elapsed >= 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:controller.trialFolder!.appendingPathComponent("试做报告.json").path)); XCTAssertEqual(try Data(contentsOf:file),original)
    }
    @MainActor func testStagedTrialRecipeDoesNotStartBatchAutomatically() throws {
        let queue = BatchQueue(storage:try root()), recipe = WorkRecipe(name:"已试做",autoCrop:true)
        queue.stage(recipe:recipe,output:URL(fileURLWithPath:"/tmp/result"),replacements:[])
        XCTAssertEqual(queue.plan?.recipe,recipe); XCTAssertFalse(queue.running)
    }
    func testEditionRejectsSameOriginalThroughPathAliases() throws {
        let root = try root(), file = try pdf(root)
        let alias = URL(fileURLWithPath:file.deletingLastPathComponent().path).appendingPathComponent(".").appendingPathComponent(file.lastPathComponent).path
        let edition = EditionCorrespondence(name:"同一本",leftPath:file.path,rightPath:alias,pairs:[.init(left:0,right:0)])
        XCTAssertThrowsError(try edition.validate(leftCount:4,rightCount:4))
    }
    @MainActor func testWholeDocumentFallbackKeepsInternalLinkDestinations() async throws {
        let root = try root(), w = try open(pdf(root),storage:root)
        let link = PDFAnnotation(bounds:CGRect(x:10,y:10,width:80,height:20),forType:.link,withProperties:nil)
        link.destination = PDFDestination(page:w.document.page(at:2)!,at:.zero); w.document.page(at:0)!.addAnnotation(link); w.changed(); w.cachedPDF = nil
        XCTAssertTrue(SnapshotSafety.requiresOriginalSerialization(w.document))
        let saved = try await w.snapshotForBackgroundSave(), doc = try XCTUnwrap(PDFDocument(data:saved.pdf))
        let destination = try XCTUnwrap(doc.page(at:0)?.annotations.first?.destination?.page)
        XCTAssertEqual(doc.index(for:destination),2)
    }
    @MainActor func testQuitFlushesLatestAcademicKeystrokeBeforeDebounce() async throws {
        let root = try root(), store = WorkspaceStore(storage:root); store.bootstrap()
        let controller = ResearchController(); controller.attachAcademicDraft(store); controller.academicText = "最后一次输入"
        let source = controller.academicSource, finished = await store.finishPendingSaves(); XCTAssertTrue(finished)
        XCTAssertEqual(try AcademicDraftStore.read(source:source,storage:root)?.text,"最后一次输入")
    }

    @MainActor func testEditionPreviewDoesNotApplyAfterSourceContextChanges() async throws {
        let root = try root(), w = try open(pdf(root),storage:root), draft = EditionAnchorDraft(), controller = ResearchController()
        controller.loadEditionLeft(draft,workspace:w); draft.generation = UUID(); try await settle(controller)
        XCTAssertNil(draft.leftPDF); XCTAssertTrue(controller.message.contains("切换"))
    }

    @MainActor func testFirstUpgradeWithLegacyRecoveryAlsoUsesSafeReview() throws {
        let root = try root(), w = try open(pdf(root),storage:root); w.dirty = true; XCTAssertTrue(w.flushRecovery())
        let store = WorkspaceStore(storage:root); store.startupSafetyEnabled = true; store.bootstrap()
        XCTAssertTrue(store.showStartupReview); XCTAssertEqual(store.activeWorkspace?.count,0)
        store.deferStartupReview(); StartupProtection(storage:root).clean()
        let next = WorkspaceStore(storage:root); next.startupSafetyEnabled = true; next.bootstrap()
        XCTAssertTrue(next.showStartupReview); XCTAssertEqual(next.activeWorkspace?.count,0)
    }

}
