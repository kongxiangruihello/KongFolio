import XCTest
import PDFKit
import AppKit
@testable import KongFolio

final class Release039Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func pdf(_ root: URL, name: String = "book.pdf", pages: Int = 4) throws -> URL { try Release038Tests().pdf(root, name: name, pages: pages) }
    @MainActor func open(_ file: URL, storage: URL) throws -> Workspace { try Release038Tests().open(file, storage: storage) }
    @MainActor func wait(_ store: WorkspaceStore) async throws {
        let end = Date().addingTimeInterval(10)
        while store.tabs.compactMap(\.workspace).contains(where: { $0.busy || $0.unloadWorker != nil }), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor func testIncrementalSnapshotPreservesUntouchedPagesAndAnnotations() async throws {
        let root = try root(), file = try pdf(root,pages: 300), w = try open(file, storage: root)
        w.document.page(at: 299)?.rotation = 90
        w.changed(); _ = try w.pdfData()
        let mark = Release038Tests().annotate(w)
        let before = w.revision, archive = try await w.snapshotForBackgroundSave()
        let doc = try XCTUnwrap(PDFDocument(data: archive.pdf))
        XCTAssertEqual(doc.pageCount,300); XCTAssertEqual(doc.page(at: 299)?.rotation,90)
        XCTAssertEqual(doc.page(at: 0)?.annotations.first?.contents,mark.contents)
        XCTAssertEqual(w.revision,before); XCTAssertTrue(w.dirty)
    }
    @MainActor func testIncrementalSnapshotAfterUndoAndFurtherEditKeepsBothChanges() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        _ = Release038Tests().annotate(w); _ = try await w.snapshotForBackgroundSave()
        w.undo(); let undone = try await w.snapshotForBackgroundSave()
        XCTAssertTrue(PDFDocument(data: undone.pdf)!.page(at: 0)!.annotations.isEmpty)
        w.redo(); _ = Release038Tests().annotate(w,text:"第二条")
        let redone = try await w.snapshotForBackgroundSave()
        XCTAssertEqual(Workspace.visibleAnnotations(on:PDFDocument(data: redone.pdf)!.page(at: 0)!).count,2)
    }
    @MainActor func testMemoryBudgetSpillsCleanBooksAndKeepsSelectedAndDirty() async throws {
        let root = try root(), store = WorkspaceStore(storage: root); store.bootstrap(); store.maxLoadedTabs = 20; store.memoryBudgetMB = 64
        var dirty: Workspace?
        for i in 0..<5 {
            let file = try pdf(root,name:"book\(i).pdf",pages:120)
            let w = i == 0 ? store.activeWorkspace! : store.addWorkspace(); store.select(w.id)
            w.load([file],prepared:.documents([try Data(contentsOf:file)]))
            if i == 0 { w.dirty = true; dirty = w }
        }
        store.loadedTabsChanged(); try await wait(store)
        XCTAssertTrue(dirty!.count > 0); XCTAssertTrue(store.activeWorkspace!.count > 0)
        XCTAssertTrue(store.tabs.compactMap(\.workspace).contains(where: \.needsLoad))
    }
    func testImportLimiterCapsParallelParsersAndCancelledWaitDoesNotLeakPermit() async throws {
        let gate = ImportLimiter(maximum: 1); try await gate.acquire()
        let waiting = Task { try await gate.acquire() }; waiting.cancel()
        do { try await waiting.value; XCTAssertTrue(false,"Cancelled import must not acquire") } catch {}
        let running = await gate.running; XCTAssertEqual(running,1)
        await gate.release(); try await gate.acquire(); await gate.release()
        let done = await gate.running; XCTAssertEqual(done,0)
    }
    func testLocalCloudPreparationDoesNotChangeFile() async throws {
        let root = try root(), file = try pdf(root), bytes = try Data(contentsOf:file)
        try await CloudFilePreparation.prepare([file]) { _ in }
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    @MainActor func testReadingGroupPersistsPositionsAndRestoresLazily() async throws {
        let root = try root(), store = WorkspaceStore(storage: root); store.bootstrap()
        for i in 0..<5 {
            let file = try pdf(root,name:"group\(i).pdf")
            let w = i == 0 ? store.activeWorkspace! : store.addWorkspace(); store.select(w.id)
            w.load([file],prepared:.documents([try Data(contentsOf:file)])); w.selectPage(2)
        }
        try store.captureReadingGroup(name:"近代报刊")
        let restored = ResearchStore(storage:root); XCTAssertEqual(restored.state.groups.first?.books.count,5)
        let group = try XCTUnwrap(restored.state.groups.first)
        let second = WorkspaceStore(storage:root.appendingPathComponent("other")); second.bootstrap(); try second.restoreReadingGroup(group); try await wait(second)
        XCTAssertEqual(second.activeWorkspace?.selection,2)
        XCTAssertTrue(second.tabs.compactMap(\.workspace).filter(\.needsLoad).count >= 4)
        XCTAssertTrue(second.tabs.compactMap(\.workspace).filter { $0.count > 0 }.count <= 1)
    }
    @MainActor func testCorruptResearchCatalogCannotBeSilentlyOverwritten() throws {
        let root = try root(), folder = root.appendingPathComponent("Research"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent("catalog.json"), bad = Data("bad".utf8); try bad.write(to:file)
        let store = ResearchStore(storage:root); XCTAssertThrowsError(try store.update { $0.citation.text = "new" }); XCTAssertEqual(try Data(contentsOf:file),bad)
    }
    @MainActor func testBackupRoundTripRestoresOriginalAndPrivateRecordsWithoutChangingSource() throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root)
        w.bookmarkName = "备份书签"; w.addBookmark(); XCTAssertTrue(w.saveDirectly(askForDestination:false))
        let original = try Data(contentsOf:file), library = BookLibrary(storage:root); try library.add([file])
        var book = library.books[0]; book.reflection = "我的心得"; try library.update(book)
        let research = ResearchStore(storage:root); try research.update { $0.labels[file.path] = [PrintedPageSegment(start:0,end:3)] }
        let backup = try ResearchBackup.capture(storage:root,catalog:library.catalog,research:research.state,progress:[:],includeOriginals:true)
        let archive = root.appendingPathComponent("all.kfresearchbackup"); try backup.write(archive,expected:FileBaseline.capture(archive))
        let result = try ResearchBackup.read(archive).restore(in:root)
        let restoredLibrary = BookLibrary(storage:result.root.appendingPathComponent("AppData")), restoredFile = URL(fileURLWithPath:restoredLibrary.books[0].path)
        XCTAssertEqual(try Data(contentsOf:restoredFile),original); XCTAssertEqual(try Data(contentsOf:file),original)
        XCTAssertEqual(restoredLibrary.books[0].reflection,"我的心得")
        XCTAssertEqual(ResearchStore(storage:result.root.appendingPathComponent("AppData")).label(path:restoredFile.path,page:0),"1")
        let reopened = try open(restoredFile,storage:result.root.appendingPathComponent("AppData")); XCTAssertEqual(reopened.bookmarks.first?.label,"备份书签")
        XCTAssertTrue(result.missing.isEmpty)
    }
    @MainActor func testBackupMissingOriginalIsListedAndDamagedPayloadRejected() throws {
        let root = try root(), file = try pdf(root), library = BookLibrary(storage:root); try library.add([file])
        var backup = try ResearchBackup.capture(storage:root,catalog:library.catalog,research:ResearchStore.State(),progress:[:],includeOriginals:false)
        try FileManager.default.removeItem(at:file)
        let result = try backup.restore(in:root); XCTAssertEqual(result.missing,[file.path])
        backup.companions = [.init(path:"../outside.json",bytes:Data(),digest:OCRPageCache.digest(Data()))]
        XCTAssertThrowsError(try backup.validate())
        backup.companions = [.init(path:"Research/x.json",bytes:Data("x".utf8),digest:"bad")]
        XCTAssertThrowsError(try backup.validate())
    }
    func testPrintedPageSegmentsRomanFrontMatterAndNoPageNumbers() throws {
        let values = [PrintedPageSegment(start:0,end:1,style:.none),PrintedPageSegment(start:2,end:5,style:.roman),PrintedPageSegment(start:6,end:9,first:1,prefix:"卷一-")]
        try PrintedPageSegment.validate(values,count:10)
        XCTAssertNil(values[0].label(0)); XCTAssertEqual(values[1].label(5),"iv"); XCTAssertEqual(values[2].label(6),"卷一-1")
        XCTAssertThrowsError(try PrintedPageSegment.validate([values[1],PrintedPageSegment(start:4,end:7)],count:10))
        XCTAssertEqual(PrintedPageSegment.roman(1999),"mcmxcix")
    }
    @MainActor func testPageLabelLookupPersistsAndJumpFindsCorrectPage() throws {
        let root = try root(), store = ResearchStore(storage:root)
        try store.update { $0.labels["/book.pdf"] = [PrintedPageSegment(start:5,end:9,first:1)] }
        let other = ResearchStore(storage:root)
        XCTAssertEqual(other.page(path:"/book.pdf",label:"3",count:10),7); XCTAssertNil(other.page(path:"/book.pdf",label:"100",count:10))
    }
    @MainActor func testPeriodicalsReportDuplicateAndInternalMissingIssues() throws {
        let store = ResearchStore(storage:try root())
        try store.update { value in
            for (i,issue) in ["1","3","3"].enumerated() { value.periodicals["/book\(i).pdf"] = PeriodicalRecord(journal:"万国公报",year:"1882",volume:"一",issue:issue) }
        }
        XCTAssertTrue(store.periodicalProblems().contains { $0.contains("缺期：2") }); XCTAssertTrue(store.periodicalProblems().contains { $0.contains("重复第 3 期") })
    }
    @MainActor func testScopedOCRDictionaryDoesNotCrossBookOrProjectAndNeverCascades() throws {
        let store = ResearchStore(storage:try root())
        try store.update { $0.dictionary = [ScopedCorrection(from:"戊",to:"戌"),ScopedCorrection(from:"戌",to:"成",scope:"/a.pdf"),ScopedCorrection(from:"府",to:"學",scope:"报刊研究")] }
        let rules = store.rules(path:"/a.pdf",project:"报刊研究")
        let hits = OCRBatchCorrection.matches(regions:[0:[RecognizedLine(text:"戊府",box:.zero)]],rules:rules)
        XCTAssertEqual(hits.map(\.to),["戌","學"])
        XCTAssertEqual(store.rules(path:"/b.pdf",project:"其他").count,1)
    }
    func testSavedAnnotationFilterCombinesTextTagsKindColorAndDate() throws {
        let now = Date(), note = ResearchAnnotation(key:"1",path:"/a.pdf",page:0,quote:"學堂",comment:"待核",kind:"高亮",color:"黄",tags:["教育"],modified:now)
        var filter = ResearchFilter(name:"教育史",text:"学堂",kind:"高亮",color:"黄",tag:"教育",after:now.addingTimeInterval(-100))
        XCTAssertTrue(filter.matches(note)); filter.before = now.addingTimeInterval(-1); XCTAssertFalse(filter.matches(note))
    }
    @MainActor func testAnnotationIndexKeepsTagsAcrossRebuildWithoutNativeIDs() async throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root)
        let mark = PDFAnnotation(bounds:CGRect(x:10,y:10,width:30,height:30),forType:.text,withProperties:nil); mark.contents = "原批注"; w.document.page(at:0)!.addAnnotation(mark)
        w.edited(pages:[0]); try w.writePDFCopy(to:file)
        let store = WorkspaceStore(storage:root); store.bootstrap(); try store.library.add([file]); try await store.indexResearchAnnotations()
        let key = try XCTUnwrap(store.research.state.annotations.first?.key)
        try store.research.update { $0.annotations[0].tags = ["待核实"] }
        try await store.indexResearchAnnotations()
        XCTAssertEqual(store.research.state.annotations.first?.key,key); XCTAssertEqual(store.research.state.annotations.first?.tags,["待核实"])
    }
    func testEditionAnchorsMapBothDirectionsAcrossPageOffsets() throws {
        let edition = EditionCorrespondence(name:"对照",leftPath:"/old.pdf",rightPath:"/new.pdf",pairs:[.init(left:0,right:2),.init(left:10,right:15)])
        XCTAssertEqual(edition.mapped(3,fromLeft:true),5); XCTAssertEqual(edition.mapped(18,fromLeft:false),13)
    }
    func testCitationTemplateIncludesPrintedPageQuoteAndReturnLink() {
        let text = CitationTemplate().render(author:"作者",title:"万国公报",periodical:"1882年第2期",page:"卷一-3",quote:"史料正文",link:"kongfolio://reading?ref=x")
        XCTAssertTrue(text.contains("第卷一-3页")); XCTAssertTrue(text.contains("史料正文")); XCTAssertTrue(text.contains("kongfolio://reading"))
    }
    func testReassociationMovesOnlyConfirmedBookmarksAndKeepsOldArchive() throws {
        let root = try root(), a = try pdf(root,pages:3), b = try pdf(root,name:"new.pdf",pages:4), oldBytes = try Data(contentsOf:a)
        var old = ProjectArchive(sourcePath:a.path,pdf:oldBytes,title:"旧版",selection:1,selectedPages:[1],mode:.document,recipes:[:],drafts:[:],dirty:false,projectPath:nil)
        old.reading = ReadingState(bookmarks:[PageBookmark(page:1,label:"重要")]); old.ocrRegions = [1:[RecognizedLine(text:"原识别",box:.zero)]]
        let result = try ReadingReassociation.apply(old,to:Data(contentsOf:b),mapping:[1:2],includeAnnotations:false)
        XCTAssertEqual(result.reading?.bookmarks.first?.page,2); XCTAssertNil(result.ocrRegions); XCTAssertNil(result.sourcePath); XCTAssertTrue(result.dirty)
        XCTAssertEqual(old.ocrRegions?[1]?.first?.text,"原识别"); XCTAssertEqual(try Data(contentsOf:a),oldBytes)
        XCTAssertThrowsError(try ReadingReassociation.apply(old,to:Data(contentsOf:b),mapping:[0:1,1:1],includeAnnotations:false))
    }
    func testReassociationDoesNotGuessBlankScanPages() throws {
        let root = try root(), file = try pdf(root), bytes = try Data(contentsOf:file)
        let proposed = try ReadingReassociation.propose(old:bytes,new:bytes)
        XCTAssertTrue(proposed.allSatisfy { $0.proposed == nil && $0.confidence == 0 })
    }
    func testAcademicWordContainsRealFootnotesEndnotesCaptionsAndPageMarkers() throws {
        let root = try root(), file = root.appendingPathComponent("academic.docx")
        let source = "# 第一章\n\n正文引用[^a]和说明[~b]。\n\n:::caption 图1 史料\n\n:::page 12\n\n下一页\n\n[^a]: 脚注内容\n[~b]: 尾注内容"
        let markup = try AcademicMarkup.parse(source)
        try RichTextWord.write(RichTextDocument(markup.text,format:.markdown),to:file,academic:markup)
        let body = try WordExportTests().unzip(["-p",file.path,"word/document.xml"])
        let foot = try WordExportTests().unzip(["-p",file.path,"word/footnotes.xml"]), end = try WordExportTests().unzip(["-p",file.path,"word/endnotes.xml"])
        XCTAssertTrue(body.contains("footnoteReference")); XCTAssertTrue(body.contains("endnoteReference")); XCTAssertTrue(body.contains("Caption")); XCTAssertTrue(body.contains("原页码：12"))
        XCTAssertTrue(foot.contains("脚注内容")); XCTAssertTrue(end.contains("尾注内容"))
        XCTAssertTrue(try WordExportTests().unzip(["-t",file.path]).contains("No errors detected"))
    }
    func testAcademicMarkupRejectsDuplicateMissingNotesAndListsDoubtfulText() throws {
        XCTAssertThrowsError(try AcademicMarkup.parse("正文[^a]")); XCTAssertThrowsError(try AcademicMarkup.parse("[^a]: 一\n[^a]: 二"))
        let parsed = try AcademicMarkup.parse("正文[待核]\n□缺字\n正常")
        XCTAssertEqual(parsed.warnings.count,2)
    }
    @MainActor func testOlderSaveCannotOverwriteNewerRecovery() throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root), writer = RecoveryWriter()
        var older = try w.snapshot(); older.title = "旧修改"
        var newer = older; newer.title = "最新修改"
        let target = root.appendingPathComponent("ordered.kfrecovery")
        try writer.flush(newer,to:target,generation:20)
        try writer.flush(older,to:target,generation:10)
        XCTAssertEqual(try ProjectArchive.read(target).title,"最新修改")
        writer.discard(target); writer.drain()
        try writer.flush(older,to:target,generation:1)
        XCTAssertEqual(try ProjectArchive.read(target).title,"旧修改")
    }
    @MainActor func testAcademicDraftSurvivesControllerRecreation() throws {
        let root = try root(), file = try pdf(root), store = WorkspaceStore(storage:root); store.bootstrap()
        store.activeWorkspace!.load([file],prepared:.documents([try Data(contentsOf:file)]))
        let first = ResearchController(); first.attachAcademicDraft(store); first.academicText = "正文[^a]\n\n[^a]: 待完善的注释"; first.flushAcademicDraft()
        let next = ResearchController(); next.attachAcademicDraft(store)
        XCTAssertEqual(next.academicText,first.academicText)
        next.flushAcademicDraft()
    }
    @MainActor func testCancelledSaveWaitingForSnapshotDoesNotBlockMainActor() async throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root)
        w.captureInProgress = true
        let waiting = Task { await w.saveInBackground() }; waiting.cancel()
        let deadline = Date().addingTimeInterval(1)
        await Task.yield(); w.captureInProgress = false
        let result = await waiting.value
        XCTAssertFalse(result); XCTAssertTrue(Date() < deadline)
    }
    @MainActor func testReadingGroupRestoreReusesAlreadyOpenedBooks() async throws {
        let root = try root(), file = try pdf(root), store = WorkspaceStore(storage:root); store.bootstrap()
        store.activeWorkspace!.load([file],prepared:.documents([try Data(contentsOf:file)]))
        try store.captureReadingGroup(name:"反复使用")
        let group = store.research.state.groups[0], before = store.tabs.count
        try store.restoreReadingGroup(group); try await wait(store)
        XCTAssertEqual(store.tabs.count,before)
    }
    @MainActor func testResearchMergePreservesCurrentPreferencesAndAddsImportedBooks() throws {
        let store = ResearchStore(storage:try root())
        try store.update { $0.labels["/a.pdf"] = [PrintedPageSegment(start:0,end:3,first:10)] }
        var imported = ResearchStore.State(); imported.labels["/a.pdf"] = [PrintedPageSegment(start:0,end:3,first:20)]; imported.labels["/b.pdf"] = [PrintedPageSegment(start:0,end:1)]
        try store.merge(imported)
        XCTAssertEqual(store.label(path:"/a.pdf",page:0),"10"); XCTAssertEqual(store.label(path:"/b.pdf",page:0),"1")
    }
    func testEditionCorrespondenceRejectsOutOfOrderAndOutOfBoundsPages() throws {
        let bad = EditionCorrespondence(name:"错误",leftPath:"/a.pdf",rightPath:"/b.pdf",pairs:[.init(left:0,right:4),.init(left:2,right:1)])
        XCTAssertThrowsError(try bad.validate(leftCount:5,rightCount:5))
        let good = EditionCorrespondence(name:"正确",leftPath:"/a.pdf",rightPath:"/b.pdf",pairs:[.init(left:0,right:1),.init(left:2,right:4)])
        try good.validate(leftCount:5,rightCount:5)
        XCTAssertThrowsError(try good.validate(leftCount:2,rightCount:5))
    }
    func testPeriodicalDateValidationRejectsImpossibleCalendarDates() throws {
        try PeriodicalRecord(journal:"万国公报",date:"1882-06-24").validate()
        XCTAssertThrowsError(try PeriodicalRecord(journal:"万国公报",date:"1882-02-30").validate())
        XCTAssertThrowsError(try PeriodicalRecord(journal:"",year:"1882").validate())
    }
    @MainActor func testBackupPreservesOCRReviewAndAcademicDrafts() throws {
        let root = try root(), file = try pdf(root), w = try open(file,storage:root)
        w.ocrRegions = [0:[RecognizedLine(text:"保留的校对文字",box:.zero)]]; w.ocrOriginals = [0:DocumentServicesTests().fixture().dataRepresentation()!]
        w.edited(pdfChanged:false); XCTAssertTrue(w.saveDirectly(askForDestination:false))
        let library = BookLibrary(storage:root); try library.add([file]); let path = library.books[0].path
        try AcademicDraftStore.write(.init(text:"研究稿",source:path,digest:w.fileBaseline?.digest,modified:Date()),storage:root)
        let backup = try ResearchBackup.capture(storage:root,catalog:library.catalog,research:ResearchStore.State(),progress:[:],includeOriginals:true)
        let result = try backup.restore(in:root), support = result.root.appendingPathComponent("AppData"), newPath = BookLibrary(storage:support).books[0].path
        let reopened = try open(URL(fileURLWithPath:newPath),storage:support)
        XCTAssertEqual(reopened.ocrRegions[0]?.first?.text,"保留的校对文字")
        XCTAssertEqual(try AcademicDraftStore.read(source:newPath,storage:support)?.text,"研究稿")
    }
    @MainActor func testBackupCarriesTextImagesAndReturnLinksToIndependentCopies() throws {
        let root = try root(), pdf = try pdf(root), image = root.appendingPathComponent("image.png"), note = root.appendingPathComponent("note.md")
        let ctx = CGContext(data:nil,width:20,height:20,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:0.5,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:20,height:20))
        try XCTUnwrap(SignatureImage.pngData(ctx.makeImage()!)).write(to:image)
        let source = SourceRef(path:pdf.path,fileName:"book.pdf",page:1,pageLabel:nil,anchor:nil)
        let link = try XCTUnwrap(SourceLink.url(source))
        let text = "![图片](image.png)\n\n[返回原文](" + link.absoluteString + ")"
        try text.write(to:note,atomically:true,encoding:.utf8)
        let library = BookLibrary(storage:root); try library.add([pdf,note])
        let backup = try ResearchBackup.capture(storage:root,catalog:library.catalog,research:ResearchStore.State(),progress:[:],includeOriginals:true)
        let result = try backup.restore(in:root), restored = BookLibrary(storage:result.root.appendingPathComponent("AppData"))
        let newNote = URL(fileURLWithPath:restored.books.first { $0.path.hasSuffix(".md") }!.path), newText = try String(contentsOf:newNote,encoding:.utf8)
        let imageRef = try XCTUnwrap(TextAssets.references(newText,format:.markdown).first)
        XCTAssertNotNil(try SignatureImage.loadData(TextMedia.read(imageRef.reference,baseURL:newNote.deletingLastPathComponent())))
        XCTAssertFalse(newText.contains(link.absoluteString)); XCTAssertEqual(try String(contentsOf:note,encoding:.utf8),text)
        XCTAssertTrue(newText.contains("kongfolio://source"))
    }
    func testBatchSampleProcessesOnlySubsetAndKeepsOriginal() throws {
        let root = try root(), file = try pdf(root,pages:10), original = try Data(contentsOf:file), doc = PDFDocument(data:original)!
        let subset = try XCTUnwrap(DocumentServices.subset(doc,indexes:[1,3]).dataRepresentation())
        let result = try BatchPipeline.process(subset,recipe:WorkRecipe(name:"试做"),replacements:[],wordURL:nil)
        XCTAssertEqual(PDFDocument(data:try XCTUnwrap(result.pdf))?.pageCount,2); XCTAssertEqual(try Data(contentsOf:file),original)
    }
    @MainActor func testUnnumberedSegmentsSuppressNativeFallbackAndMergeRetainsIdentity() throws {
        let root = try root(), store = ResearchStore(storage:root)
        var imported = ResearchStore.State(); imported.labels["/book.pdf"] = [PrintedPageSegment(start:0,end:1,style:.none)]; imported.identities = ["/book.pdf":"digest"]
        try store.merge(imported)
        XCTAssertEqual(store.displayLabel(path:"/book.pdf",page:0,fallback:"i"),"无印刷页码")
        XCTAssertEqual(store.displayLabel(path:"/book.pdf",page:2,fallback:"1"),"1")
        XCTAssertEqual(store.state.identities?["/book.pdf"],"digest")
    }
    @MainActor func testAcademicTablesRemainRealWordTablesAndFirstPageHasNoLeadingBreak() throws {
        let root = try root(), target = root.appendingPathComponent("tables.docx")
        let text = ":::page i\n\n# 第一章\n\n" + ResearchController.markdownTable([["甲","乙"],["一","二"]]) + "\n\n:::page ii\n\n# 第二章\n\n正文"
        let parsed = try AcademicMarkup.parse(text), document = try RichTextDocument(parsed.text,format:.markdown)
        try RichTextWord.write(document,to:target,academic:parsed)
        let xml = try WordExportTests().unzip(["-p",target.path,"word/document.xml"])
        XCTAssertTrue(xml.contains("<w:tbl>")); XCTAssertTrue(xml.contains("二"))
        XCTAssertEqual(xml.components(separatedBy:"w:type=\"page\"").count-1,1)
        XCTAssertFalse(xml.contains("<w:pageBreakBefore/>"))
    }
    func testTruncatedAndOutOfRangeBackupManifestIsRejected() throws {
        let root = try root(), target = root.appendingPathComponent("broken.kfresearchbackup")
        let backup = ResearchBackup(catalog:BookLibrary.Catalog(),research:ResearchStore.State(),originals:[:],companions:[],progress:[:])
        try backup.write(target,expected:FileBaseline.capture(target))
        var bytes = try Data(contentsOf:target); bytes.removeLast(2); try bytes.write(to:target)
        XCTAssertThrowsError(try ResearchBackup.read(target))
        var manifest = ResearchBackup.Manifest(metadata:backup,originals:["/fake.pdf":.init(offset:Int.max,length:1)],companions:[])
        manifest.metadata.originalDigests = ["/fake.pdf":"x"]
        let json = try JSONEncoder().encode(manifest); var length = UInt64(json.count).bigEndian
        bytes = ResearchBackup.magic; withUnsafeBytes(of:&length) { bytes.append(contentsOf:$0) }; bytes.append(json); try bytes.write(to:target)
        XCTAssertThrowsError(try ResearchBackup.read(target))
    }

}
