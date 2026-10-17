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

    @MainActor func marks(_ workspace: Workspace, _ type: String) -> [PDFAnnotation] {
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

final class AnnotationDigestTests: XCTestCase {
    func sample() -> [AnnotationNote] {
        [
            AnnotationNote(page: 0, index: 0, kind: "高亮", quote: "學而時習之", note: "开篇", colorName: "黄"),
            AnnotationNote(page: 1, index: 0, kind: "高亮", quote: "有朋自遠方來", note: "", colorName: "绿"),
            AnnotationNote(page: 2, index: 0, kind: "下划线", quote: "人不知而不慍", note: "君子", colorName: "黄"),
            AnnotationNote(page: 3, index: 0, kind: "批注", quote: "", note: "待查注疏"),
        ]
    }

    func testFilterByKindColourAndText() {
        XCTAssertEqual(AnnotationFilter().apply(to: sample()).count, 4)
        XCTAssertEqual(AnnotationFilter(kind: "高亮").apply(to: sample()).count, 2)
        XCTAssertEqual(AnnotationFilter(color: "黄").apply(to: sample()).count, 2)
        XCTAssertEqual(AnnotationFilter(kind: "高亮", color: "黄").apply(to: sample()).map(\.page), [0])
        XCTAssertEqual(AnnotationFilter(text: "君子").apply(to: sample()).map(\.page), [2])
        XCTAssertEqual(AnnotationFilter(text: "注疏").apply(to: sample()).map(\.page), [3])
        XCTAssertEqual(AnnotationFilter(text: "  ").apply(to: sample()).count, 4)
        XCTAssertFalse(AnnotationFilter().isActive)
        XCTAssertTrue(AnnotationFilter(color: "绿").isActive)
    }

    func testColourNames() {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        XCTAssertEqual(MarkupColor.nearest(to: rgb(1, 0.8, 0)), .yellow)
        XCTAssertEqual(MarkupColor.nearest(to: rgb(0.2, 0.78, 0.35)), .green)
        XCTAssertEqual(MarkupColor.nearest(to: rgb(0, 0.48, 1)), .blue)
        XCTAssertEqual(MarkupColor.nearest(to: rgb(1, 0.18, 0.33)), .pink)
        XCTAssertNil(MarkupColor.nearest(to: rgb(0, 0, 0)))
        XCTAssertNil(MarkupColor.nearest(to: rgb(0.5, 0.5, 0.5)))
    }

    func testMarkdownNamesTheColour() {
        let markdown = ReadingServices.markdown(title: "论语", notes: sample())
        XCTAssertTrue(markdown.contains("### 高亮（黄）"))
        XCTAssertTrue(markdown.contains("### 下划线（黄）"))
        XCTAssertTrue(markdown.contains("### 批注\n"))
    }

    @MainActor func testNotesReportMarkColours() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        let workspace = Workspace(storage: directory)
        workspace.document = try TextImport.render("学而时习之，不亦说乎？", markdown: false)
        let view = PDFView(); view.document = workspace.document; workspace.pdfView = view
        view.setCurrentSelection(try workspace.document.findString("学而时习之", withOptions: []).first.unwrap("没有找到文字"), animate: false)
        workspace.mark(style: .highlight, color: .green)
        let notes = ReadingServices.notes(workspace.document)
        XCTAssertEqual(notes.first?.colorName, "绿")
        XCTAssertEqual(notes.first?.kind, "高亮")
        XCTAssertEqual(AnnotationFilter(color: "绿").apply(to: notes).count, notes.count)
        XCTAssertTrue(AnnotationFilter(color: "粉").apply(to: notes).isEmpty)
    }
}

final class PenStyleTests: XCTestCase {
    func testPenKeepsTheChosenWidth() {
        XCTAssertEqual(PenStyle.make(width: 3, highlighter: false, arrow: false), PenStyle(width: 3, alpha: 1))
        XCTAssertEqual(PenStyle.make(width: 100, highlighter: false, arrow: false).width, 24)
        XCTAssertEqual(PenStyle.make(width: 0, highlighter: false, arrow: false).width, 0.5)
    }

    func testHighlighterIsWideAndTranslucent() {
        let style = PenStyle.make(width: 2, highlighter: true, arrow: false)
        XCTAssertTrue(style.width >= 10)
        XCTAssertTrue(style.alpha < 0.5)
        XCTAssertEqual(PenStyle.make(width: 6, highlighter: true, arrow: false).width, 24)
    }

    func testArrowsIgnoreTheHighlighter() {
        XCTAssertEqual(PenStyle.make(width: 2, highlighter: true, arrow: true), PenStyle(width: 2, alpha: 1))
    }
}
