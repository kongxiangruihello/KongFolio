import XCTest
import AppKit
@testable import KongFolio

final class Release043Tests: XCTestCase {
    @MainActor func input(_ text:String) -> ComposingTextView {
        let view = ComposingTextView(frame:NSRect(x:0,y:0,width:400,height:300)); view.isRichText = false; view.allowsUndo = true; view.string = text; return view
    }
    @MainActor func testChineseCompositionIsNeverWrittenBackOrSavedHalfway() {
        var model = "第一行\n第二行", writes:[String] = []
        let coordinator = StableInputCoordinator(read:{model},write:{model = $0; writes.append($0)}), view = input(model)
        view.delegate = coordinator; view.committed = { coordinator.publish($0) }; view.setSelectedRange(NSRange(location:3,length:0))
        view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(view.hasMarkedText()); coordinator.publish(view); coordinator.synchronize(view)
        XCTAssertEqual(model,"第一行\n第二行"); XCTAssertTrue(writes.isEmpty); XCTAssertTrue(view.string.contains("zhong"))
        view.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0)); coordinator.publish(view)
        XCTAssertFalse(view.hasMarkedText()); XCTAssertEqual(model,"第一行中文\n第二行"); XCTAssertEqual(writes,[model])
    }
    @MainActor func testRepeatedModelRefreshKeepsFirstLineCaretAndSelection() {
        var model = "- 第一项\n- 第二项", writes = 0
        let c = StableInputCoordinator(read:{model},write:{model = $0; writes += 1}), view = input(model)
        view.setSelectedRange(NSRange(location:3,length:1))
        for _ in 0..<200 { c.synchronize(view) }
        XCTAssertEqual(view.selectedRange(),NSRange(location:3,length:1)); XCTAssertEqual(view.string,model); XCTAssertEqual(writes,0)
    }
    @MainActor func testTypingThenEchoDoesNotDuplicateTextOrMoveToSecondLine() {
        var model = "- 甲\n- 乙"
        let c = StableInputCoordinator(read:{model},write:{model = $0}), view = input(model); view.delegate = c; view.committed = { c.publish($0) }; view.setSelectedRange(NSRange(location:3,length:0))
        for _ in 0..<30 { view.insertText("中",replacementRange:NSRange(location:NSNotFound,length:0)); c.synchronize(view) }
        XCTAssertEqual(model,"- 甲"+String(repeating:"中",count:30)+"\n- 乙"); XCTAssertEqual(view.selectedRange(),NSRange(location:33,length:0))
    }
    @MainActor func testNormalizedTagsDoNotOverwriteTheCommaStillBeingTyped() {
        var model = "史料"
        let c = StableInputCoordinator(read:{model},write:{model = $0.replacingOccurrences(of:",",with:"").trimmingCharacters(in:.whitespaces)}), view = input("史料, ")
        c.publish(view); c.synchronize(view); XCTAssertEqual(view.string,"史料, "); XCTAssertEqual(model,"史料")
    }
    @MainActor func testExternalTextChangeKeepsCaretWithEmojiAndLeadingInsertion() {
        let view = input("甲😀乙\n二"); view.setSelectedRange(NSRange(location:4,length:0))
        TextInputSync.replaceExternal(view,with:"前甲😀乙\n二"); XCTAssertEqual(view.selectedRange(),NSRange(location:5,length:0)); XCTAssertEqual(view.string,"前甲😀乙\n二")
    }
    @MainActor func testMarkedTextSurvivesUnrelatedExternalRefresh() {
        let view = input("正文"); view.setSelectedRange(NSRange(location:2,length:0)); view.setMarkedText("pin",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        TextInputSync.replaceExternal(view,with:"正文"); XCTAssertTrue(view.hasMarkedText()); XCTAssertEqual(view.string,"正文pin")
    }
    @MainActor func testNativeUndoSurvivesModelEcho() {
        let view = Undo043TextView(frame:NSRect(x:0,y:0,width:300,height:150)); view.isRichText = false; view.allowsUndo = true; view.string = "甲\n乙"
        var model = view.string
        let c = StableInputCoordinator(read:{model},write:{model = $0}); view.delegate = c; view.committed = { c.publish($0) }; view.setSelectedRange(NSRange(location:1,length:0))
        view.history.groupsByEvent = false; view.history.beginUndoGrouping(); view.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0)); view.breakUndoCoalescing(); view.history.endUndoGrouping(); c.synchronize(view)
        XCTAssertTrue(view.history.canUndo); view.history.undo(); c.publish(view); XCTAssertEqual(model,"甲\n乙"); XCTAssertEqual(view.string,model)
    }
    func testListToggleKeepsCaretInFirstLine() {
        let added = MarkdownNote.lineEdit(in:"第一项\n第二项",selection:NSRange(location:2,length:0),prefix:"- ")
        XCTAssertEqual(added.replacement,"- 第一项\n"); XCTAssertEqual(added.selection,NSRange(location:4,length:0))
        let removed = MarkdownNote.lineEdit(in:"- 第一项\n- 第二项",selection:NSRange(location:4,length:0),prefix:"- ")
        XCTAssertEqual(removed.replacement,"第一项\n"); XCTAssertEqual(removed.selection,NSRange(location:2,length:0))
    }
    func testListSelectionEndingAtNextLineStartDoesNotFormatNextLine() {
        let edit = MarkdownNote.lineEdit(in:"甲\n乙",selection:NSRange(location:0,length:2),prefix:"- ")
        XCTAssertEqual(edit.range,NSRange(location:0,length:2)); XCTAssertEqual(edit.replacement,"- 甲\n"); XCTAssertEqual(edit.selection,NSRange(location:2,length:2))
    }
    func testMultiLineListSelectionRetainsBothSelectedCharacters() {
        let edit = MarkdownNote.lineEdit(in:"甲\n乙",selection:NSRange(location:0,length:3),prefix:"- ")
        XCTAssertEqual(edit.replacement,"- 甲\n- 乙"); XCTAssertEqual(edit.selection,NSRange(location:2,length:5))
    }
    @MainActor func testLibraryFindsAllKindsAndKeepsOrderWhileEditing() throws {
        let j = ReadingJournal(storage:try Release027Tests().folder()); let date = Date()
        let note = ReadingRecord(kind:.note,note:"教育思想",created:date), quote = ReadingRecord(kind:.excerpt,quote:"思想史原文",created:date.addingTimeInterval(-1))
        j.add(note); j.add(quote); let essay = j.newEssay(title:"教育札记")
        let first = ReadingLibraryItem.results(j.state).map(\.id)
        j.editRecord(quote.id) { $0.note = "新的解释" }
        XCTAssertEqual(ReadingLibraryItem.results(j.state).map(\.id),first)
        XCTAssertEqual(ReadingLibraryItem.results(j.state,kind:"札记").map(\.id),[.essay(essay)]); XCTAssertEqual(ReadingLibraryItem.results(j.state,kind:"笔记").map(\.id),[.record(note.id)])
        XCTAssertEqual(ReadingLibraryItem.results(j.state,query:"教育").count,2)
    }
    @MainActor func testMixedLibraryDeleteAndRestoreKeepTextImagesAndFrozenCitations() async throws {
        let root = try Release027Tests().folder(), j = ReadingJournal(storage:root)
        let record = ReadingRecord(kind:.image,quote:"原文",note:"评论",citations:[ReadingCitation(source:SourceRef(path:"/原书.pdf",fileName:"原书.pdf",page:3),title:"原书")],imageAsset:"image.png"); j.add(record); let essay = j.newEssay(title:"札记"); j.insert(record,in:essay)
        let ids:Set<ReadingLibraryID> = [.record(record.id),.essay(essay)]; j.setRemoved(ids,removed:true); try await j.flush()
        XCTAssertTrue(ReadingLibraryItem.results(j.state).isEmpty); XCTAssertEqual(ReadingLibraryItem.results(j.state,removed:true).count,2)
        let reopened = ReadingJournal(storage:root); reopened.setRemoved(ids,removed:false); try await reopened.flush()
        XCTAssertEqual(ReadingLibraryItem.results(reopened.state).count,2); XCTAssertEqual(reopened.record(record.id)?.note,"评论"); XCTAssertEqual(reopened.record(record.id)?.imageAsset,"image.png"); XCTAssertEqual(reopened.essay(essay)?.blocks.last?.record,record)
    }
    @MainActor func testManualExcerptUsesTransientDraftUntilItHasText() async throws {
        let j = ReadingJournal(storage:try Release027Tests().folder()), record = ReadingRecord(kind:.excerpt); j.beginNote(record); try await j.flush(); XCTAssertTrue(j.state.records.isEmpty)
        j.editRecord(record.id) { $0.quote = "手动整理的摘录" }; try await j.flush(); XCTAssertEqual(j.state.records.count,1); XCTAssertEqual(j.record(record.id)?.quote,"手动整理的摘录")
    }
}

@MainActor final class Undo043TextView: ComposingTextView {
    let history = UndoManager()
    override var undoManager:UndoManager? { history }
}
