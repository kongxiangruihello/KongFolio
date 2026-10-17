import XCTest
import PDFKit
@testable import KongFolio

final class OutlineEditingTests: XCTestCase {
    @MainActor func workspace(pages: Int = 10) throws -> (Workspace, URL) {
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

    @MainActor func testEntriesStayInPageOrderAndNestOneLevelAtATime() throws {
        let (workspace, directory) = try workspace(); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.selection = 5
        workspace.addOutlineEntry(title: "第二章", depth: 0)
        workspace.selection = 1
        workspace.addOutlineEntry(title: "第一章", depth: 0)
        workspace.selection = 2
        workspace.addOutlineEntry(title: "第一节", depth: 3)       // asked for too deep: at most one under the chapter
        workspace.selection = 7
        workspace.addOutlineEntry(title: "", depth: 0)
        XCTAssertEqual(workspace.outlineEntries.map(\.label), ["第一章", "第一节", "第二章", "第 8 页"])
        XCTAssertEqual(workspace.outlineEntries.map(\.depth), [0, 1, 0, 0])
        XCTAssertEqual(workspace.outlineEntries.map(\.page), [1, 2, 5, 7])
    }

    @MainActor func testRenameIndentDeleteAndUndo() throws {
        let (workspace, directory) = try workspace(); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.selection = 0; workspace.addOutlineEntry(title: "甲", depth: 0)
        workspace.selection = 3; workspace.addOutlineEntry(title: "乙", depth: 0)
        let second = workspace.outlineEntries[1].id
        workspace.indentOutlineEntry(second, by: 1)
        XCTAssertEqual(workspace.outlineEntries[1].depth, 1)
        workspace.indentOutlineEntry(second, by: 1)                    // already one under the entry above
        XCTAssertEqual(workspace.outlineEntries[1].depth, 1)
        workspace.indentOutlineEntry(workspace.outlineEntries[0].id, by: 1)       // the first entry cannot nest
        XCTAssertEqual(workspace.outlineEntries[0].depth, 0)
        workspace.renameOutlineEntry(second, to: "  乙章  ")
        XCTAssertEqual(workspace.outlineEntries[1].label, "乙章")
        workspace.deleteOutlineEntry(second)
        XCTAssertEqual(workspace.outlineEntries.count, 1)
        workspace.undo()
        XCTAssertEqual(workspace.outlineEntries.map(\.label), ["甲", "乙章"])
    }

    @MainActor func testTheOutlineIsWrittenIntoThePDF() throws {
        let (workspace, directory) = try workspace(); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.selection = 2; workspace.addOutlineEntry(title: "序", depth: 0)
        workspace.selection = 6; workspace.addOutlineEntry(title: "正文", depth: 0)
        let saved = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取")
        let outline = ReadingServices.outline(saved)
        XCTAssertEqual(outline.map(\.label), ["序", "正文"])
        XCTAssertEqual(outline.map(\.page), [2, 6])
        // And chapter splitting now has something to split by.
        XCTAssertEqual(workspace.chapterCount(depth: 0), 2)
    }
}
