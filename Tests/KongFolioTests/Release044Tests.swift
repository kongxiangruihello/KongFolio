import XCTest
import AppKit
import CoreText
@testable import KongFolio

final class Release044Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func note(_ text:String = "原有笔记") -> ReadingRecord { ReadingRecord(kind:.note,note:text,citations:[ReadingCitation(source:SourceRef(path:"/原书.pdf",fileName:"原书.pdf",page:4),title:"原书")]) }
    func date(_ day:Int) -> Date { Date(timeIntervalSince1970:1_700_000_000+Double(day)*86400) }
    func testDailyBackupIsOncePerDayAndRetainsThirtyDailyCopies() throws {
        let folder = try root(), state = ReadingJournalState(records:[note()])
        for day in 0..<35 { try ReadingBackupStorage.daily(state,folder:folder,date:date(day)); try ReadingBackupStorage.daily(state,folder:folder,date:date(day)) }
        let manual = try ReadingBackupStorage.capture(state,folder:folder,kind:.manual,date:date(0)), list = try ReadingBackupStorage.list(folder)
        XCTAssertEqual(list.filter{$0.kind == .daily}.count,30); XCTAssertTrue(list.contains{$0.id == manual.id}); XCTAssertFalse(list.contains{$0.kind == .daily && $0.date == date(0)})
    }
    @MainActor func testAutomaticSaveCreatesIndependentDailyBackup() async throws {
        let j = ReadingJournal(storage:try root()), r = note(); j.add(r); try await j.flush()
        let copies = try ReadingBackupStorage.list(j.folder); XCTAssertEqual(copies.filter{$0.kind == .daily}.count,1); XCTAssertEqual(copies.first?.state.records.first?.note,"原有笔记")
        j.editRecord(r.id) { $0.note = "今天后续的修改" }; try await j.flush(); XCTAssertEqual(try ReadingBackupStorage.list(j.folder).filter{$0.kind == .daily}.count,1)
    }
    @MainActor func testRestoringOneRecordPreservesOthersAndKeepsBeforeRestoreCopy() async throws {
        let root = try root(), j = ReadingJournal(storage:root), a = note(), b = note("不要改变的记录"); j.add(a); j.add(b); let copy = try await j.makeBackup()
        j.editRecord(a.id) { $0.note = "修改后"; $0.removed = Date() }; j.editRecord(b.id) { $0.note = "另一本书的新思考" }; try await j.flush()
        try await j.restoreBackup(copy.id,ids:[.record(a.id)])
        let reopened = ReadingJournal(storage:root); XCTAssertEqual(reopened.record(a.id)?.note,"原有笔记"); XCTAssertNil(reopened.record(a.id)?.removed); XCTAssertEqual(reopened.record(b.id)?.note,"另一本书的新思考")
        let before = try XCTUnwrap(ReadingBackupStorage.list(j.folder).first{$0.kind == .beforeRestore}); XCTAssertEqual(before.state.records.first{$0.id == a.id}?.note,"修改后")
    }
    @MainActor func testBackupImagesAreIndependentAndRestoredWithoutOverwritingLiveImage() async throws {
        let root = try root(), j = ReadingJournal(storage:root), image = Data("图片原始内容".utf8); var r = note(); r.kind = .image
        let id = j.add(r,image:image); let copy = try await j.makeBackup(); let name = try XCTUnwrap(j.record(id)?.imageAsset)
        try Data("后来损坏的图片".utf8).write(to:j.assetURL(name),options:.atomic)
        let selected = try ReadingBackupStorage.selection(copy.id,ids:[.record(id)],folder:j.folder)
        XCTAssertEqual(selected.assets.values.first,image)
        try await j.restoreBackup(copy.id,ids:[.record(id)])
        let restored = try XCTUnwrap(j.record(id)?.imageAsset); XCTAssertFalse(restored == name); XCTAssertEqual(try Data(contentsOf:j.assetURL(restored)),image)
        XCTAssertEqual(try Data(contentsOf:j.assetURL(name)),Data("后来损坏的图片".utf8)); XCTAssertEqual(j.record(id)?.note,"原有笔记")
    }
    @MainActor func testCorruptBackupAndPathTraversalNeverReplaceCurrentRecords() async throws {
        let j = ReadingJournal(storage:try root()), r = note(); j.add(r); let copy = try await j.makeBackup(); let file = try ReadingBackupStorage.file(copy.id,folder:j.folder)
        var broken = copy; broken.state.records[0].note = "被改动"; try JSONEncoder().encode(broken).write(to:file)
        do { try await j.restoreBackup(copy.id,ids:[.record(r.id)]); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(j.record(r.id)?.note,"原有笔记"); XCTAssertThrowsError(try ReadingBackupStorage.read("../catalog",folder:j.folder))
    }
    @MainActor func testMissingBackupImageAbortsBeforeAnyRecordChanges() async throws {
        let j = ReadingJournal(storage:try root()), image = Data("原图".utf8), r = note(); j.add(r,image:image); let copy = try await j.makeBackup(); let hash = try XCTUnwrap(copy.assets.values.first)
        try FileManager.default.removeItem(at:ReadingBackupStorage.root(j.folder).appendingPathComponent("Assets").appendingPathComponent(hash))
        j.editRecord(r.id) { $0.note = "不能被覆盖的新笔记" }; try await j.flush()
        do { try await j.restoreBackup(copy.id,ids:[.record(r.id)]); XCTAssertTrue(false) } catch {}
        XCTAssertEqual(j.record(r.id)?.note,"不能被覆盖的新笔记")
    }
    @MainActor func testBackupFailureDoesNotPreventJournalSave() async throws {
        let root = try root(), j = ReadingJournal(storage:root); try FileManager.default.createDirectory(at:j.folder,withIntermediateDirectories:true)
        try Data("这里不能创建目录".utf8).write(to:ReadingBackupStorage.root(j.folder))
        let r = note(); j.add(r); try await j.flush(); XCTAssertNotNil(j.backupError); XCTAssertEqual(ReadingJournal(storage:root).record(r.id)?.note,"原有笔记"); XCTAssertFalse(j.dirty)
    }
    func testBackupRejectsSymlinkDirectory() throws {
        let folder = try root(), other = try root(); try FileManager.default.createSymbolicLink(at:ReadingBackupStorage.root(folder),withDestinationURL:other)
        XCTAssertThrowsError(try ReadingBackupStorage.capture(ReadingJournalState(records:[note()]),folder:folder,kind:.manual)); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:other.path).isEmpty)
    }
    @MainActor func testBacklinksIncludeFrozenEssayAndSoftDeletedNotes() throws {
        let j = ReadingJournal(storage:try root()), quote = ReadingRecord(kind:.excerpt,quote:"原文内容"); j.add(quote)
        var n = note(); n.linkedRecords = [quote.id]; j.add(n); let essay = j.newEssay(title:"札记"); j.insert(quote,in:essay); j.insert(quote,in:essay)
        j.editRecord(quote.id) { $0.quote = "后来改过" }; j.setRemoved([.record(n.id)],removed:true)
        let refs = j.references(to:.record(quote.id)); XCTAssertEqual(refs.incoming.count,2); XCTAssertTrue(refs.incoming.contains{$0.removed})
        let outgoing = j.references(to:.essay(essay)).outgoing; XCTAssertEqual(outgoing.count,1); XCTAssertTrue(outgoing[0].text.contains("原文内容")); XCTAssertFalse(outgoing[0].text.contains("后来改过"))
    }
    @MainActor func testBatchTagsAndTopicsPreserveExistingMetadataAndFrozenCopies() async throws {
        let j = ReadingJournal(storage:try root()); var r = note(); r.tags = ["已有标签"]; j.add(r); let e = j.newEssay(title:"专题札记"); j.insert(r,in:e)
        j.organize([.record(r.id),.essay(e)],tags:"教育，史料,教育",topic:"近代教育")
        XCTAssertEqual(j.record(r.id)?.tags,["已有标签","教育","史料","专题：近代教育"]); XCTAssertEqual(j.topics,["近代教育"]); XCTAssertEqual(j.essay(e)?.blocks.last?.record?.tags,["已有标签"])
        j.organize([.record(r.id)],tags:"教育",topic:"",remove:true); XCTAssertFalse(try XCTUnwrap(j.record(r.id)).tags.contains("教育")); XCTAssertTrue(try XCTUnwrap(j.essay(e)).tags.contains("教育"))
        try await j.flush(); XCTAssertEqual(ReadingJournal(storage:j.folder.deletingLastPathComponent()).topics,["近代教育"])
    }
    func testExportPreferencesPersistAndRejectInvalidSettings() throws {
        let defaults = UserDefaults(suiteName:"Export044-"+UUID().uuidString)!; var value = ReadingExportPreferences(); value.format = .pdf; value.options.fontSize = 16; value.options.includeQuote = false; value.directoryPath = try root().path; value.save(defaults:defaults)
        XCTAssertEqual(ReadingExportPreferences.load(defaults:defaults),value); XCTAssertNotNil(value.directoryURL)
        value.options.fontSize = -1; defaults.set(try JSONEncoder().encode(value),forKey:ReadingExportPreferences.key); XCTAssertEqual(ReadingExportPreferences.load(defaults:defaults),ReadingExportPreferences())
    }
    func testExportContentOptionsDoNotLeakExcludedTextThroughHeadings() throws {
        let r = ReadingRecord(kind:.excerpt,quote:"不应出现的原文",note:"保留的思考",citations:[ReadingCitation(source:SourceRef(path:"/书.pdf",fileName:"书.pdf",page:0),title:"不应出现的出处")])
        var options = ReadingExportOptions(); options.includeQuote = false; options.includeSources = false
        let snapshot = ReadingExportSnapshot(title:"导出",records:[r],options:options), md = ReadingRecordExport.markdown(snapshot,imageFolder:"images")
        XCTAssertFalse(md.contains("不应出现")); XCTAssertTrue(md.contains("保留的思考")); XCTAssertFalse(md.contains("kongfolio://"))
        let rich = try ReadingRecordExport.rich(snapshot,assets:try root()); XCTAssertFalse(rich.blocks.contains { if case .paragraph(let text,_) = $0 { return text.string.contains("不应出现") }; return false })
    }
    func testExportFontAndOptionsInvalidatePreviewDigest() throws {
        var a = ReadingExportSnapshot(title:"札记",records:[note()],options:ReadingExportOptions()), b = a; b.options?.fontSize = 18
        XCTAssertFalse(a.digest == b.digest); let rich = try ReadingRecordExport.rich(b,assets:try root()); XCTAssertEqual(rich.options.fontSize,18)
        a.options?.includeNote = false; XCTAssertFalse(a.digest == b.digest)
    }
    @MainActor func testEditorUndoHistoriesAreIndependentAndClearedOnClose() {
        let a = ComposingTextView(), b = ComposingTextView(); XCTAssertFalse(a.undoManager === b.undoManager)
        a.undoManager?.registerUndo(withTarget:a) { $0.string = "旧文字" }; a.finishEditingSession(); XCTAssertFalse(a.undoManager?.canUndo ?? true)
    }
    @MainActor func testSustainedChineseEditingAcrossRecordSwitches() async throws {
        let duration = min(600,max(1,Double(ProcessInfo.processInfo.environment["KONGFOLIO_LONG_INPUT_SECONDS"] ?? "1") ?? 1)), root = try root(), journal = ReadingJournal(storage:root)
        var entries = (0..<12).map { i in ReadingRecord(kind:.note,title:"持续输入-\(i)",note:String(repeating:"长篇中文与史料。",count:250)+"\n第二行保持不变") }
        for r in entries { journal.add(r) }; try await journal.flush()
        var beats = 0, count = 0; let started = Date()
        let ticker = Task { @MainActor in while !Task.isCancelled { beats += 1; try? await Task.sleep(nanoseconds:10_000_000) } }; defer { ticker.cancel() }
        while Date().timeIntervalSince(started) < duration {
            let index = count % entries.count, id = entries[index].id
            let view = ComposingTextView(frame:NSRect(x:0,y:0,width:400,height:180)); view.isRichText = false; view.allowsUndo = true; view.string = journal.record(id)!.note
            let c = StableInputCoordinator(read:{journal.record(id)?.note ?? ""},write:{text in journal.editRecord(id) { $0.note = text } }); view.delegate = c; view.committed = { c.publish($0) }
            let position = (view.string as NSString).range(of:"\n").location; view.setSelectedRange(NSRange(location:position,length:0)); let before = journal.record(id)!.note
            view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0)); c.synchronize(view); XCTAssertEqual(journal.record(id)?.note,before)
            view.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0)); c.synchronize(view); XCTAssertEqual(view.selectedRange(),NSRange(location:position+2,length:0)); XCTAssertTrue(view.string.hasSuffix("\n第二行保持不变"))
            entries[index] = journal.record(id)!; view.finishEditingSession(); count += 1
            if count % 25 == 0 { try await journal.flush() }; try await Task.sleep(nanoseconds:10_000_000)
        }
        try await journal.flush(); let reopened = ReadingJournal(storage:root); for r in entries { XCTAssertEqual(reopened.record(r.id)?.note,r.note) }; XCTAssertTrue(beats > 5); XCTAssertTrue(count > 5)
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_LONG_INPUT_REPORT"] {
            let report:[String:Any] = ["elapsedSeconds":Date().timeIntervalSince(started),"compositionCommits":count,"mainActorHeartbeats":beats,"records":entries.count,"reopenedTextMatches":true]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
    }
}
