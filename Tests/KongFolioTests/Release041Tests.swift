import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release041Tests:XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func citation(_ path:String = "/原书.pdf",page:Int = 2) -> ReadingCitation { ReadingCitation(source:SourceRef(path:path,fileName:"原书.pdf",page:page,pageLabel:"十二"),title:"史料选编",author:"作者甲") }
    func record(_ path:String = "/原书.pdf") -> ReadingRecord { ReadingRecord(kind:.excerpt,quote:"这是原文。",note:"这是自己的思考。",citations:[citation(path)],tags:["史料"]) }
    func image() throws -> Data { let image = NSImage(size:NSSize(width:40,height:30),flipped:false) { rect in NSColor.white.setFill(); rect.fill(); return true }; return try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using:.png,properties:[:])) }
    @MainActor func testReadAndRefreshNeverAutomaticallyAddsToShelf() async throws {
        let root = try root(), file = try Release038Tests().pdf(root), library = BookLibrary(storage:root), defaults = UserDefaults(suiteName:"ManualShelf-"+UUID().uuidString)!
        ReadingProgress(last:1,date:Date(),pages:2).save(path:file.path,defaults:defaults)
        _ = try await library.refreshHistory(defaults:defaults); XCTAssertTrue(library.books.isEmpty)
        let store = WorkspaceStore(storage:root,readingDefaults:defaults); store.bootstrap(); store.openEach([file]); try await Release038Tests().settle(store.activeWorkspace!); XCTAssertTrue(store.library.books.isEmpty)
        try library.add([file]); XCTAssertEqual(library.books.count,1); _ = try await library.refreshHistory(defaults:defaults); XCTAssertEqual(library.books.count,1)
    }
    @MainActor func testLegacyShelfIsPreservedForManualConfirmation() throws {
        let root = try root(), folder = root.appendingPathComponent("Library"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let a = LibraryBook(path:"/旧书甲.pdf",title:"旧书甲",category:"原有分类",reflection:"我的心得"), b = LibraryBook(path:"/旧书乙.pdf",title:"旧书乙")
        var old = BookLibrary.Catalog(books:[a,b]); old.manualOnly = nil
        let bytes = try JSONEncoder().encode(old); try bytes.write(to:folder.appendingPathComponent("catalog.json"))
        let library = BookLibrary(storage:root); XCTAssertTrue(library.books.isEmpty); XCTAssertEqual(library.catalog.pendingBooks?.count,2)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("catalog-before-0.41.json")),bytes)
        try library.acceptPending([a.id]); XCTAssertEqual(library.books.map(\.id),[a.id]); XCTAssertEqual(library.books[0].reflection,"我的心得"); XCTAssertEqual(library.books[0].category,"原有分类")
        let reopened = BookLibrary(storage:root); XCTAssertEqual(reopened.books.count,1); XCTAssertEqual(reopened.catalog.pendingBooks?.count,1)
    }
    @MainActor func testRemovingShelfBookDoesNotLoseMetadataOrReaddIt() async throws {
        let root = try root(), file = try Release038Tests().pdf(root), library = BookLibrary(storage:root), defaults = UserDefaults(suiteName:"RemoveShelf-"+UUID().uuidString)!
        try library.add([file]); var book = library.books[0]; book.reflection = "保留笔记"; try library.update(book); try library.removeBooks([book.id])
        ReadingProgress(last:1,date:Date(),pages:2).save(path:file.path,defaults:defaults); _ = try await library.refreshHistory(defaults:defaults)
        XCTAssertTrue(library.books.isEmpty); XCTAssertEqual(library.catalog.pendingBooks?.first?.reflection,"保留笔记")
        try library.add([file]); XCTAssertEqual(library.books.first?.id,book.id)
    }
    @MainActor func testJournalPersistsImageNotesAndLastEditedBook() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), bytes = try image(); var entry = record(); entry.kind = .image
        let id = journal.add(entry,image:bytes); journal.editRecord(id) { $0.note = "最后输入" }; try await journal.flush()
        let reopened = ReadingJournal(storage:root); XCTAssertEqual(reopened.record(id)?.note,"最后输入"); XCTAssertEqual(reopened.state.lastNotes["/原书.pdf"],id)
        let name = try XCTUnwrap(reopened.record(id)?.imageAsset); XCTAssertEqual(try Data(contentsOf:reopened.assetURL(name)),bytes)
        XCTAssertFalse(reopened.dirty); XCTAssertNil(reopened.error)
    }
    @MainActor func testOverlappingFlushesPersistTheLatestEdit() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), id = journal.add(record())
        let first = Task { try await journal.flush() }
        journal.editRecord(id) { $0.note = String(repeating:"最后的理解",count:2000) }
        let second = Task { try await journal.flush() }; try await first.value; try await second.value
        XCTAssertEqual(ReadingJournal(storage:root).record(id)?.note,String(repeating:"最后的理解",count:2000)); XCTAssertFalse(journal.dirty)
    }
    @MainActor func testCorruptJournalIsNotOverwrittenAndPreviousCanBeRecovered() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), id = journal.add(record()); try await journal.flush(); journal.editRecord(id) { $0.note = "第二版" }; try await journal.flush()
        let file = journal.folder.appendingPathComponent("catalog.json"), damaged = Data("损坏记录".utf8); try damaged.write(to:file)
        let bad = ReadingJournal(storage:root); XCTAssertTrue(bad.unreadable); _ = bad.add(record("/另一书.pdf"))
        do { try await bad.flush(); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(try Data(contentsOf:file),damaged); try bad.recoverPrevious(); XCTAssertEqual(bad.record(id)?.quote,"这是原文。")
        let copies = try FileManager.default.contentsOfDirectory(at:bad.folder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("catalog.damaged-")}; XCTAssertEqual(copies.count,1); XCTAssertEqual(try Data(contentsOf:copies[0]),damaged)
    }
    @MainActor func testLegacyImportIsIdempotentAndDoesNotOpenOriginals() async throws {
        let journal = ReadingJournal(storage:try root()), card = BoardCard(kind:.text,text:"旧摘录",comment:"旧评论",source:SourceRef(path:"/不存在的云端书.pdf",fileName:"云端书",page:2),x:0,y:0,width:200,height:120)
        let book = LibraryBook(path:"/不存在的云端书.pdf",title:"云端书",reflection:"旧心得")
        await journal.importLegacy(cards:[card],books:[book],topics:[],annotations:[]); await journal.importLegacy(cards:[card],books:[book],topics:[],annotations:[])
        XCTAssertEqual(journal.state.records.count,2); XCTAssertEqual(journal.record(card.id)?.note,"旧评论"); try await journal.flush()
    }
    @MainActor func testEssayKeepsFrozenQuoteAndRemovedRecordCanBeRestored() async throws {
        let journal = ReadingJournal(storage:try root()), ref = record(), essay = journal.newEssay(title:"我的札记"); journal.add(ref); journal.insert(ref,in:essay)
        journal.editRecord(ref.id) { $0.quote = "后来改过的摘录"; $0.removed = Date() }
        XCTAssertEqual(journal.essay(essay)?.blocks.last?.record?.quote,"这是原文。")
        let block = try XCTUnwrap(journal.essay(essay)?.blocks.last); journal.editEssay(essay) { $0.move(block.id,delta:-1) }
        XCTAssertEqual(journal.essay(essay)?.blocks.first?.id,block.id); journal.editRecord(ref.id) { $0.removed = nil }; XCTAssertNil(journal.record(ref.id)?.removed)
        try await journal.flush(); XCTAssertEqual(ReadingJournal(storage:journal.folder.deletingLastPathComponent()).essay(essay)?.title,"我的札记")
    }
    func testSearchIncludesAuthorPageTagAndOwnNote() {
        let ref = record(); XCTAssertTrue(ref.matches("作者甲")); XCTAssertTrue(ref.matches("十二")); XCTAssertTrue(ref.matches("自己的思考",tag:"史料")); XCTAssertFalse(ref.matches("",book:"/另一书.pdf")); XCTAssertFalse(ref.matches("",tag:"不存在"))
        let essay = ReadingEssay(title:"札记",blocks:[ReadingEssay.Block(text:"关于教育的论述",record:ref)])
        XCTAssertTrue(essay.matches("教育")); XCTAssertTrue(essay.matches("史料选编"))
    }
    func testExportDigestDoesNotChangeWithoutEdits() {
        let snapshot = ReadingExportSnapshot(title:"同一份记录",records:[record()]); XCTAssertEqual(snapshot.digest,snapshot.digest)
    }
    @MainActor func testMarkdownWordAndPDFKeepImagesLiteralTextAndSourceLinks() async throws {
        let root = try root(), journal = ReadingJournal(storage:root); var ref = record(); ref.quote = "# 原文 [特殊] **文字** <史料> & 内容"; ref.note = "自己的笔记\n第二段"
        journal.add(ref,image:try image()); try await journal.flush(); ref = try XCTUnwrap(journal.record(ref.id))
        let snapshot = ReadingExportSnapshot(title:"导出核对",records:[ref]), assets = journal.folder.appendingPathComponent("Assets")
        for format in ReadingRecordExport.Format.allCases {
            let file = root.appendingPathComponent("带空格的笔记."+format.ext); try ReadingRecordExport.write(snapshot,format:format,assets:assets,to:file,expected:FileBaseline.capture(file))
            if format == .word {
                let xml = try WordExportTests().unzip(["-p",file.path,"word/document.xml"]); XCTAssertTrue(xml.contains("原文 [特殊] **文字** &lt;史料&gt; &amp; 内容")); XCTAssertTrue(xml.contains("自己的笔记")); XCTAssertTrue(xml.contains("返回原文")); XCTAssertTrue(xml.contains("作者甲"))
                let relations = try WordExportTests().unzip(["-p",file.path,"word/_rels/document.xml.rels"]); XCTAssertTrue(relations.contains("kongfolio://source")); XCTAssertTrue(relations.contains("relationships/image"))
            } else if format == .pdf { let document = try XCTUnwrap(PDFDocument(url:file)); XCTAssertTrue((document.string ?? "").contains("自己的笔记")); XCTAssertTrue(document.pageCount > 0) }
            else { let md = try String(contentsOf:file); XCTAssertTrue(md.contains("\\# 原文")); XCTAssertTrue(md.contains("[返回原文](kongfolio://source")); let copy = root.appendingPathComponent("带空格的笔记-images").appendingPathComponent(ref.imageAsset!); XCTAssertTrue(FileManager.default.fileExists(atPath:copy.path)) }
        }
    }
    func testExportRejectsTheOriginalAndHardLink() throws {
        let root = try root(), file = try Release038Tests().pdf(root), original = try Data(contentsOf:file), alias = root.appendingPathComponent("原件别名.docx"); try FileManager.default.linkItem(at:file,to:alias)
        let snapshot = ReadingExportSnapshot(title:"记录",records:[record(file.path)])
        XCTAssertThrowsError(try ReadingRecordExport.write(snapshot,format:.word,assets:root,to:file,expected:FileBaseline.capture(file)))
        XCTAssertThrowsError(try ReadingRecordExport.write(snapshot,format:.word,assets:root,to:alias,expected:FileBaseline.capture(alias))); XCTAssertEqual(try Data(contentsOf:file),original)
    }
    @MainActor func testRelinkingRecordsAndEssayDoesNotImplicitlyAddShelfBook() async throws {
        let root = try root(), store = WorkspaceStore(storage:root), replacement = try Release038Tests().pdf(root,name:"移动后的书.pdf"), ref = record("/已移动.pdf")
        store.journal.add(ref); let essay = store.journal.newEssay(); store.journal.insert(ref,in:essay)
        try store.library.relink(path:"/已移动.pdf",to:replacement,defaults:store.readingDefaults)
        XCTAssertTrue(store.library.books.isEmpty); XCTAssertEqual(store.journal.record(ref.id)?.citations.first?.source.path,replacement.path); XCTAssertEqual(store.journal.essay(essay)?.blocks.last?.record?.citations.first?.source.path,replacement.path)
    }
    func testCancellationClassificationDoesNotHideRealFailures() {
        XCTAssertTrue(FolioCancellation.matches(CancellationError())); XCTAssertTrue(FolioCancellation.matches(NSError(domain:"Swift.CancellationError",code:1)))
        XCTAssertTrue(FolioCancellation.matches(NSError(domain:"wrapper",code:4,userInfo:[NSUnderlyingErrorKey:CancellationError()])))
        XCTAssertFalse(FolioCancellation.matches(NSError(domain:NSCocoaErrorDomain,code:4))); XCTAssertFalse(FolioCancellation.matches(FolioError(message:"保存失败")))
    }
    @MainActor func testCancelledOldRecoveryDoesNotInterruptNormalReading() async throws {
        let root = try root(), file = try Release038Tests().pdf(root,pages:160), w = try Release038Tests().open(file,storage:root)
        w.bookmarks = [PageBookmark(page:0,label:"读书位置")]; w.cachedPDF = nil; w.scheduleRecovery()
        let deadline = Date().addingTimeInterval(8)
        while !w.preparingSnapshot, Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(w.preparingSnapshot); w.selectPage(5)
        let saved = Date().addingTimeInterval(8)
        while !w.recoveryStatus.contains("已自动保存"), Date() < saved { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertNil(w.error); XCTAssertEqual(w.selection,5); XCTAssertTrue(w.recoveryStatus.contains("已自动保存")); XCTAssertTrue(FileManager.default.fileExists(atPath:w.recoveryURL.path))
        w.report { throw CancellationError() }; XCTAssertNil(w.error); w.error = "真实保存失败"; w.recordError(CancellationError()); XCTAssertEqual(w.error,"真实保存失败")
    }
    @MainActor func testPlainTextDoesNotRenderAnUnusedPreview() async throws {
        let note = MarkdownNote(text:"纯文本记录",storage:try root(),format:.plain); note.refreshPreview(); try await Task.sleep(nanoseconds:500_000_000); XCTAssertNil(note.preview)
        XCTAssertTrue(try note.renderDocument().pageCount > 0)
    }
    @MainActor func testBackupSelectsJournalAssetsAndCanRestoreRecordsWithEmptyShelf() async throws {
        let root = try root(), journal = ReadingJournal(storage:root), a = record("/甲.pdf"), b = record("/乙.pdf")
        journal.add(a,image:try image()); journal.add(b); try await journal.flush()
        let catalog = BookLibrary.Catalog(books:[LibraryBook(path:"/甲.pdf",title:"甲"),LibraryBook(path:"/乙.pdf",title:"乙")])
        let backup = try ResearchBackup.capture(storage:root,catalog:catalog,research:ResearchStore.State(),progress:[:],includeOriginals:false)
        let selected = try backup.selecting(["/甲.pdf"],includeShared:false), bytes = try XCTUnwrap(selected.companions.first{$0.path == "ReadingJournal/catalog.json"}?.bytes)
        XCTAssertEqual(try JSONDecoder().decode(ReadingJournalState.self,from:bytes).records.map(\.id),[a.id]); XCTAssertTrue(selected.companions.contains{$0.path.hasPrefix("ReadingJournal/Assets/")})
        let onlyNotes = try backup.selecting([],includeShared:true); XCTAssertTrue(onlyNotes.catalog.books.isEmpty)
        let restoreFolder = root.appendingPathComponent("恢复"); try FileManager.default.createDirectory(at:restoreFolder,withIntermediateDirectories:true)
        let restored = try onlyNotes.restore(in:restoreFolder); let transfer = try XCTUnwrap(ReadingJournalTransfer.read(restored.root.appendingPathComponent("AppData/ReadingJournal")))
        let destination = ReadingJournal(storage:root.appendingPathComponent("新资料")); destination.merge(transfer); try await destination.flush(); XCTAssertEqual(destination.state.records.count,2)
    }
}
