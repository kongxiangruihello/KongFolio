import XCTest
import AppKit
@testable import KongFolio

final class ReadingEditing059Tests: XCTestCase {
    func testQuotedChineseContinuesAtCaretAndEmptyQuoteExits() throws {
        let text = "> 引用甲🙂乙\n2. 后文"
        let caret = "> 引用甲🙂".utf16.count
        let edit = try XCTUnwrap(WritingEdit.quoteNewline(text,selection:NSRange(location:caret,length:0)))
        XCTAssertEqual((text as NSString).replacingCharacters(in:edit.range,with:edit.replacement),"> 引用甲🙂\n> 乙\n2. 后文")
        XCTAssertEqual(edit.selection.location,caret+3)
        let empty = "> 原文\n> > "
        let exit = try XCTUnwrap(WritingEdit.quoteNewline(empty,selection:NSRange(location:empty.utf16.count,length:0)))
        XCTAssertEqual((empty as NSString).replacingCharacters(in:exit.range,with:exit.replacement),"> 原文\n")
        XCTAssertNil(WritingEdit.quoteNewline("普通段落",selection:NSRange(location:2,length:0)))
    }

    @MainActor func testNativeQuoteContinuationAndUndoKeepCommittedChinese() throws {
        var model = "> 第一行\n第二行"
        let coordinator = StableInputCoordinator(read:{model},write:{model = $0})
        let view = Release043Tests().input(model)
        let session = WritingSession()
        session.view = view
        view.delegate = coordinator
        view.committed = { coordinator.publish($0) }
        view.continuesMarkdownQuotes = true
        let history = try XCTUnwrap(view.undoManager)
        history.groupsByEvent = false
        history.beginUndoGrouping()
        view.setSelectedRange(NSRange(location:5,length:0))
        view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:view.selectedRange())
        session.replayUndo()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(model,"> 第一行\n第二行")
        view.insertText("中",replacementRange:view.markedRange())
        view.breakUndoCoalescing()
        history.endUndoGrouping()
        view.insertNewline(nil)
        XCTAssertEqual(model,"> 第一行中\n> \n第二行")
        session.replayUndo()
        XCTAssertEqual(model,"> 第一行中\n第二行")
        session.replayUndo(redo:true)
        XCTAssertEqual(model,"> 第一行中\n> \n第二行")
    }

    @MainActor func testSegmentCorrectionPreservesOtherEditsAndOriginalSources() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let source = ReadingCitation(source:SourceRef(path:"/tmp/vol.pdf",fileName:"vol.pdf",page:1),title:"原刊")
        var record = ReadingRecord(kind:.excerpt,quote:"甲原文",citations:[source])
        record.appendExcerpt(ReadingRecord(kind:.excerpt,quote:"乙原文",citations:[source]))
        let id = try XCTUnwrap(record.excerptSegments?.first?.id)
        let second = try XCTUnwrap(record.excerptSegments?.last?.id)
        journal.add(record)
        journal.editRecord(record.id) { $0.excerptRemark = "同时新增的备注";$0.reviseExcerptSegment(second,text:"乙校订") }
        try journal.applyQuoteCorrection(record,text:"甲校订",segmentID:id)
        let updated = try XCTUnwrap(journal.record(record.id))
        XCTAssertEqual(updated.quote,"甲校订\n\n乙校订")
        XCTAssertEqual(updated.excerptRemark,"同时新增的备注")
        XCTAssertEqual(updated.excerptSegments?.first?.originalText,"甲原文")
        XCTAssertEqual(updated.excerptSegments?.first?.sources(in:updated),[source])
        XCTAssertThrowsError(try journal.applyQuoteCorrection(record,text:"过期校订",segmentID:id))
        XCTAssertThrowsError(try journal.applyQuoteCorrection(updated,text:" \n ",segmentID:id))
    }

    @MainActor func testQuoteCorrectionCanSaveAlongsideChangedNote() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let record = ReadingRecord(kind:.excerpt,quote:"原文")
        journal.add(record)
        journal.editRecord(record.id) { $0.note = "新笔记" }
        try journal.applyQuoteCorrection(record,text:"改正原文")
        XCTAssertEqual(journal.record(record.id)?.note,"新笔记")
        XCTAssertEqual(journal.record(record.id)?.originalQuote,"原文")
    }
}
