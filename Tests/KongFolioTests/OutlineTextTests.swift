import XCTest
import PDFKit
@testable import KongFolio

final class OutlineTextTests: XCTestCase {
    func testRoundTripWithAnOffset() {
        let entries = [OutlineEntry(page: 11, label: "序", depth: 0), OutlineEntry(page: 13, label: "卷之一", depth: 0), OutlineEntry(page: 20, label: "第一章", depth: 1)]
        let text = OutlineText.serialize(entries, offset: 10)
        XCTAssertEqual(text, "序\t2\n卷之一\t4\n  第一章\t11")
        let back = OutlineText.parse(text, offset: 10, pageCount: 100)
        XCTAssertEqual(back.problems, [])
        XCTAssertEqual(back.entries.map(\.label), ["序", "卷之一", "第一章"])
        XCTAssertEqual(back.entries.map(\.page), [11, 13, 20])
        XCTAssertEqual(back.entries.map(\.depth), [0, 0, 1])
    }

    func testPastedContentsLinesAreRead() {
        let text = "目錄 1\n卷一 …… 3\n\t第一節 . . . 5\n卷二·········12\n  第二節  １５\n"
        let result = OutlineText.parse(text, offset: 0, pageCount: 50)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.entries.map(\.label), ["目錄", "卷一", "第一節", "卷二", "第二節"])
        XCTAssertEqual(result.entries.map(\.page), [0, 2, 4, 11, 14])            // 15 typed in full-width digits
        XCTAssertEqual(result.entries.map(\.depth), [0, 0, 1, 0, 1])
    }

    func testLevelsNeverJumpMoreThanOneStep() {
        let result = OutlineText.parse("甲 1\n        乙 2\n丙 3", offset: 0, pageCount: 10)
        XCTAssertEqual(result.entries.map(\.depth), [0, 1, 0])
        XCTAssertEqual(OutlineText.parse("          甲 1", offset: 0, pageCount: 10).entries.map(\.depth), [0])     // the first entry is top level
    }

    func testUnreadableLinesAreReportedAndSkipped() {
        let result = OutlineText.parse("甲 1\n没有页码的行\n 7\n乙 99\n丙 0\n丁 3", offset: 0, pageCount: 10)
        XCTAssertEqual(result.entries.map(\.label), ["甲", "丁"])
        XCTAssertEqual(result.problems.count, 4)
        XCTAssertTrue(result.problems[0].contains("第 2 行没有页码"))
        XCTAssertTrue(result.problems[1].contains("第 3 行没有标题"))
        XCTAssertTrue(result.problems[2].contains("超出范围"))
        XCTAssertTrue(result.problems[3].contains("第 5 行"))
    }

    @MainActor func workspace(pages: Int) -> (Workspace, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        let workspace = Workspace(storage: directory)
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
            document.insert(page, at: index)
        }
        workspace.document = PDFDocument(data: document.dataRepresentation()!)!
        return (workspace, directory)
    }

    @MainActor func testApplyingTextReplacesTheOutlineAndCanBeUndone() throws {
        let (workspace, directory) = workspace(pages: 20); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.selection = 3
        workspace.addOutlineEntry(title: "旧的", depth: 0)
        workspace.applyOutlineText("序 2\n卷一 5\n  第一章 6", offset: 0)
        XCTAssertEqual(workspace.outlineEntries.map(\.label), ["序", "卷一", "第一章"])
        XCTAssertEqual(workspace.outlineEntries.map(\.page), [1, 4, 5])
        let saved = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取")
        XCTAssertEqual(ReadingServices.outline(saved).map(\.label), ["序", "卷一", "第一章"])
        workspace.undo()
        XCTAssertEqual(workspace.outlineEntries.map(\.label), ["旧的"])
        // Nothing readable: the outline stays and an error is shown.
        workspace.applyOutlineText("全是废话", offset: 0)
        XCTAssertEqual(workspace.outlineEntries.map(\.label), ["旧的"])
        XCTAssertNotNil(workspace.error)
        // Empty text clears the outline.
        workspace.error = nil
        workspace.applyOutlineText("", offset: 0)
        XCTAssertTrue(workspace.outlineEntries.isEmpty)
    }
}
