import XCTest
import PDFKit
@testable import KongFolio

final class MarkingTests: XCTestCase {
    @MainActor func setup() throws -> (Workspace, PDFView, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        let workspace = Workspace(storage: directory)
        workspace.document = try TextImport.render("学而时习之，不亦说乎？\n有朋自远方来，不亦乐乎？", markdown: false)
        let view = PDFView()
        view.document = workspace.document
        workspace.pdfView = view
        view.setCurrentSelection(try workspace.document.findString("学而时习之", withOptions: []).first.unwrap("没有找到文字"), animate: false)
        return (workspace, view, directory)
    }

    func marks(_ workspace: Workspace, _ type: String) -> [PDFAnnotation] {
        (0..<workspace.count).flatMap { workspace.document.page(at: $0)?.annotations ?? [] }.filter { $0.type == type }
    }

    @MainActor func testMarkingTheSelectionKeepsTheQuoteAndClearsTheSelection() throws {
        let (workspace, view, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let added = workspace.mark(style: .underline, color: .green)
        XCTAssertFalse(added.isEmpty)
        XCTAssertFalse(marks(workspace, "Underline").isEmpty)
        XCTAssertTrue(added.allSatisfy { ($0.value(forAnnotationKey: ReadingServices.quoteKey) as? String)?.isEmpty == false })
        XCTAssertNil(view.currentSelection)
    }

    @MainActor func testMarkWithNoteSelectsTheNewMarkAndCanBeUndone() throws {
        let (workspace, _, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.mark(style: .highlight, color: .yellow, annotate: true)
        XCTAssertNotNil(workspace.selectedAnnotation)
        XCTAssertFalse(marks(workspace, "Highlight").isEmpty)
        workspace.undo()
        XCTAssertTrue(marks(workspace, "Highlight").isEmpty)
    }

    @MainActor func testMarkingWithoutASelectionDoesNothing() throws {
        let (workspace, view, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        view.clearSelection()
        XCTAssertTrue(workspace.mark(style: .highlight, color: .yellow).isEmpty)
        XCTAssertTrue(marks(workspace, "Highlight").isEmpty)
    }
}
