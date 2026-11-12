import AppKit
import XCTest
@testable import KongFolio

final class ReadingEditingTests: XCTestCase {
    private func apply(_ edit: TextEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in:edit.range,with:edit.replacement)
    }

    func testReturnRenumbersSiblingsAndKeepsNestedLists() throws {
        let text = "9. 甲\n   1. 子\n10. 乙\n11. 丙\n\n1. 另一组"
        let edit = try XCTUnwrap(WritingEdit.newline(text,selection:NSRange(location:4,length:0)))
        XCTAssertEqual(apply(edit,to:text),"9. 甲\n10. \n   1. 子\n11. 乙\n12. 丙\n\n1. 另一组")
        XCTAssertEqual(edit.selection.location,9)
    }

    func testReturnAtMarkerDoesNotRemoveFollowingTextAndTabKeepsCaret() throws {
        let text = "- 史料"
        let selection = NSRange(location:2,length:0)
        XCTAssertEqual(apply(try XCTUnwrap(WritingEdit.newline(text,selection:selection)),to:text),"- \n- 史料")
        let edit = try XCTUnwrap(WritingEdit.indent(text,selection:selection,outdent:false))
        XCTAssertEqual(apply(edit,to:text),"  - 史料")
        XCTAssertEqual(edit.selection,NSRange(location:4,length:0))
    }

    func testParagraphMovementAndSplitUseUTF16AndPreserveLinks() throws {
        let text = "甲𠮷\n\n[出处](kongfolio://source)\n\n丙"
        let selected = (text as NSString).range(of:"出处")
        let move = try XCTUnwrap(WritingEdit.paragraph(.up,text:text,selection:selected))
        let moved = apply(move,to:text)
        XCTAssertEqual(moved,"[出处](kongfolio://source)\n\n甲𠮷\n\n丙")
        XCTAssertEqual((moved as NSString).substring(with:move.selection),"出处")
        let split = try XCTUnwrap(WritingEdit.paragraph(.split,text:"甲𠮷丙",selection:NSRange(location:3,length:0)))
        XCTAssertEqual(apply(split,to:"甲𠮷丙"),"甲𠮷\n\n丙")
    }

    func testStructuredNoteKeepsFrozenSourceWhenMovingSplittingAndMerging() throws {
        let source = ReadingRecord(kind:.excerpt,quote:"来源甲")
        let other = ReadingRecord(kind:.excerpt,quote:"来源乙")
        let first = ReadingEssay.Block(text:"甲𠮷乙",record:source)
        let second = ReadingEssay.Block(text:"另一段",record:other)
        var essay = ReadingEssay(blocks:[first,second])
        XCTAssertFalse(essay.mergeWithNext(first.id))
        let continuation = try XCTUnwrap(essay.split(first.id,at:3))
        XCTAssertEqual(essay.blocks.map(\.text),["甲𠮷","乙","另一段"])
        XCTAssertEqual(essay.blocks.first?.record,source)
        XCTAssertNil(essay.blocks[1].record)
        XCTAssertEqual(essay.blocks[1].id,continuation)
        XCTAssertTrue(essay.mergeWithNext(first.id))
        essay.move(first.id,delta:1)
        XCTAssertEqual(essay.blocks.last?.record,source)
        XCTAssertEqual(essay.blocks.last?.text,"甲𠮷\n\n乙")
        XCTAssertEqual(essay.blocks.first?.record,other)
    }

    func testProofreadingCanApplyOnlySelectedChangesIncludingInsertionAndDeletion() throws {
        let original = "甲誤乙𠮷丙。末"
        let revised = "甲正乙𠮷新增丙末"
        let plan = try QuoteProofreading(original:original,revised:revised)
        XCTAssertEqual(plan.applying(Set(plan.changes.map(\.id))),revised)
        XCTAssertEqual(plan.applying([]),original)
        let correction = try XCTUnwrap(plan.changes.first { $0.original == "誤" })
        XCTAssertEqual(plan.applying([correction.id]),"甲正乙𠮷丙。末")
        let reverted = NSMutableString(string:revised)
        for change in plan.changes.reversed() {
            reverted.replaceCharacters(in:change.revisedRange,with:change.original)
        }
        XCTAssertEqual(reverted as String,original)
    }

    func testCleanupPreservesBlankLinesVariantGlyphsAndPunctuation() {
        let source = "異體\r\n字。\r\n \r\nword\r\nbreak\r\n"
        XCTAssertEqual(WritingCleanup().apply(source),source)
        XCTAssertEqual(WritingCleanup(joinLines:true).apply(source),"異體字。\n \nword break\n")
    }

    @MainActor func testFindScopeMapsBackToSelectionAndReplacesInOneUndo() throws {
        let view = ComposingTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.string = "甲舊文 乙舊文 丙舊文"
        let session = WritingSession()
        session.view = view
        view.setSelectedRange(NSRange(location:4,length:3))
        session.beginFind()
        session.searchSelectionOnly = true
        session.find("舊文")
        XCTAssertEqual(view.selectedRange(),NSRange(location:5,length:2))
        session.replace("舊文",with:"新",all:true)
        session.endFind()
        XCTAssertEqual(view.string,"甲舊文 乙新 丙舊文")
        XCTAssertEqual(view.selectedRange(),NSRange(location:4,length:2))
        view.undoManager?.undo()
        XCTAssertEqual(view.string,"甲舊文 乙舊文 丙舊文")
    }
}
