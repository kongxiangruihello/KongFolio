import XCTest
import PDFKit
import SwiftUI
@testable import KongFolio

final class AnnotationShapesTests: XCTestCase {
    let style = PenStyle(width: 2, alpha: 1)

    func testAStraightStrokeSnapsToFifteenDegrees() {
        let snapped = AnnotationShapes.snapped(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(snapped.y, 0, accuracy: 0.001)
        XCTAssertEqual(snapped.x, (100.0 * 100.0 + 8.0 * 8.0).squareRoot(), accuracy: 0.001)
        let diagonal = AnnotationShapes.snapped(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 52))
        XCTAssertEqual(diagonal.x - 10, diagonal.y - 10, accuracy: 0.5)
        XCTAssertEqual(AnnotationShapes.snapped(from: .zero, to: .zero), CGPoint.zero)
    }

    func testTheBoxFollowsTheDragAndCanBeMadeSquare() {
        let free = AnnotationShapes.box(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20), square: false)
        XCTAssertEqual(free, CGRect(x: 10, y: 20, width: 40, height: 30))
        let square = AnnotationShapes.box(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20), square: true)
        XCTAssertEqual(square, CGRect(x: 10, y: 10, width: 40, height: 40))
    }

    func testALineHasNoArrowHeadAndAnArrowDoes() throws {
        let points = [CGPoint(x: 40, y: 60), CGPoint(x: 140, y: 60)]
        let line = try AnnotationShapes.make(tool: .line, points: points, style: style, color: .red, fill: false, constrained: false).unwrap("没有生成")
        XCTAssertEqual(line.type, "Line")
        XCTAssertEqual(line.endLineStyle == .none, true)
        XCTAssertEqual(line.endPoint.x - line.startPoint.x, 100, accuracy: 0.001)
        let arrow = try AnnotationShapes.make(tool: .arrow, points: points, style: style, color: .red, fill: false, constrained: false).unwrap("没有生成")
        XCTAssertEqual(arrow.endLineStyle == .openArrow, true)
    }

    func testShapesAreSquaresAndCirclesWithAnOptionalFill() throws {
        let points = [CGPoint(x: 40, y: 60), CGPoint(x: 140, y: 100)]
        let rectangle = try AnnotationShapes.make(tool: .rectangle, points: points, style: style, color: .blue, fill: false, constrained: false).unwrap("没有生成")
        XCTAssertEqual(rectangle.type, "Square")
        XCTAssertTrue(rectangle.bounds.contains(CGRect(x: 40, y: 60, width: 100, height: 40)))
        XCTAssertEqual(rectangle.interiorColor == nil, true)
        let ellipse = try AnnotationShapes.make(tool: .ellipse, points: points, style: style, color: .blue, fill: true, constrained: true).unwrap("没有生成")
        XCTAssertEqual(ellipse.type, "Circle")
        XCTAssertEqual(ellipse.bounds.width, ellipse.bounds.height, accuracy: 0.001)
        XCTAssertEqual(ellipse.interiorColor == nil, false)
    }

    func testToolsThatPlaceInsteadOfDragProduceNothing() {
        XCTAssertEqual(AnnotationShapes.make(tool: .note, points: [.zero], style: style, color: .red, fill: false, constrained: false) == nil, true)
        XCTAssertEqual(AnnotationShapes.make(tool: .pen, points: [], style: style, color: .red, fill: false, constrained: false) == nil, true)
        for tool in [AnnotationTool.pen, .line, .arrow, .rectangle, .ellipse, .signature] { XCTAssertTrue(tool.draws) }
        for tool in [AnnotationTool.select, .edit, .note, .textBox, .region] { XCTAssertFalse(tool.draws) }
    }

    func testDrawnMarksSurviveSavingAndAreListed() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil).unwrap("无画布")
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try PDFDocument(data: data as Data).unwrap("无法读取")
        let page = try document.page(at: 0).unwrap("无页面")
        let strokes: [(AnnotationTool, [CGPoint])] = [
            (.line, [CGPoint(x: 20, y: 30), CGPoint(x: 120, y: 30)]),
            (.arrow, [CGPoint(x: 20, y: 60), CGPoint(x: 120, y: 90)]),
            (.rectangle, [CGPoint(x: 20, y: 120), CGPoint(x: 120, y: 180)]),
            (.ellipse, [CGPoint(x: 150, y: 120), CGPoint(x: 250, y: 180)]),
            (.pen, [CGPoint(x: 20, y: 220), CGPoint(x: 60, y: 240), CGPoint(x: 100, y: 220)]),
        ]
        for (tool, points) in strokes {
            let annotation = try AnnotationShapes.make(tool: tool, points: points, style: style, color: .red, fill: false, constrained: false).unwrap("没有生成")
            page.addAnnotation(annotation)
        }
        let reloaded = try PDFDocument(data: document.dataRepresentation().unwrap("无法保存")).unwrap("保存结果无法读取")
        let kinds = Set((reloaded.page(at: 0)?.annotations ?? []).compactMap(\.type))
        XCTAssertEqual(kinds, ["Line", "Square", "Circle", "Ink"])
        XCTAssertEqual(reloaded.page(at: 0)?.annotations.count, 5)
        let listed = ReadingServices.notes(reloaded).map(\.kind)
        XCTAssertTrue(listed.contains("矩形") && listed.contains("椭圆") && listed.contains("箭头/线条") && listed.contains("手写"))
        XCTAssertTrue(AnnotationFilter.kinds.contains("矩形") && AnnotationFilter.kinds.contains("椭圆"))
    }

    @MainActor func testATextBoxGrowsWithItsText() {
        XCTAssertEqual(AnnotationText.boxHeight(for: "短"), 30, accuracy: 0.001)
        XCTAssertTrue(AnnotationText.boxHeight(for: String(repeating: "字", count: 60)) > AnnotationText.boxHeight(for: "短"))
        XCTAssertTrue(AnnotationText.boxHeight(for: "一\n二\n三") > AnnotationText.boxHeight(for: "一"))
    }
}

final class AnnotationBarBehaviourTests: XCTestCase {
    @MainActor func workspace() -> Workspace {
        Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
    }

    @MainActor func testTheBarIsClosedUntilAskedFor() {
        UserDefaults.standard.removeObject(forKey: "KongFolio.annotationBar2")
        XCTAssertFalse(workspace().showAnnotationBar)
    }

    @MainActor func testClosingTheBarGoesBackToReading() {
        let space = workspace()
        space.showAnnotationBar = true
        space.selectTool(.pen)
        XCTAssertEqual(space.tool, AnnotationTool.pen)
        space.showAnnotationBar = false
        XCTAssertEqual(space.tool, AnnotationTool.select)
        UserDefaults.standard.removeObject(forKey: "KongFolio.annotationBar2")
    }

    @MainActor func testEachToolKeepsItsOwnColourAndWidth() {
        let space = workspace()
        space.selectTool(.pen)
        XCTAssertEqual(space.penWidth, 2, accuracy: 0.001)
        space.penWidth = 6
        space.annotationColor = Color(.sRGB, red: 0, green: 0.6, blue: 0, opacity: 1)
        space.selectTool(.pen, highlighter: true)
        XCTAssertTrue(space.penHighlighter)
        XCTAssertEqual(space.penWidth, 3, accuracy: 0.001)
        let marker = NSColor(space.annotationColor).usingColorSpace(.sRGB)
        XCTAssertTrue((marker?.redComponent ?? 0) > 0.9 && (marker?.blueComponent ?? 1) < 0.1)
        space.selectTool(.pen)
        XCTAssertFalse(space.penHighlighter)
        XCTAssertEqual(space.penWidth, 6, accuracy: 0.001)
        let pen = NSColor(space.annotationColor).usingColorSpace(.sRGB)
        XCTAssertTrue((pen?.greenComponent ?? 0) > 0.5 && (pen?.redComponent ?? 1) < 0.1)
    }

    func testKeysChooseTools() {
        XCTAssertEqual(AnnotationShortcuts.tool(for: "L")?.tool, AnnotationTool.line)
        XCTAssertEqual(AnnotationShortcuts.tool(for: "h")?.highlighter, true)
        XCTAssertEqual(AnnotationShortcuts.tool(for: "x")?.tool, AnnotationTool.eraser)
        XCTAssertEqual(AnnotationShortcuts.tool(for: "z") == nil, true)
        let keys = ["v", "p", "h", "l", "a", "r", "o", "t", "n", "e", "x"]
        XCTAssertEqual(Set(keys.compactMap { AnnotationShortcuts.tool(for: $0).map { "\($0.tool.rawValue)\($0.highlighter)" } }).count, keys.count)
    }

    func testDashedStrokesAreDashedAndPenStrokesAreNot() throws {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 60)]
        let style = PenStyle(width: 2, alpha: 1)
        let rectangle = try AnnotationShapes.make(tool: .rectangle, points: points, style: style, color: .red, fill: false, constrained: false, dashed: true).unwrap("没有生成")
        XCTAssertEqual(rectangle.border?.style == .dashed, true)
        let solid = try AnnotationShapes.make(tool: .rectangle, points: points, style: style, color: .red, fill: false, constrained: false).unwrap("没有生成")
        XCTAssertEqual(solid.border?.style == .solid, true)
        let pen = try AnnotationShapes.make(tool: .pen, points: points, style: style, color: .red, fill: false, constrained: false, dashed: true).unwrap("没有生成")
        XCTAssertEqual(pen.border?.style == .solid, true)
    }

    func testEveryDrawingToolHasADefaultStyleAndTheEraserDoesNotDraw() {
        for tool in [AnnotationTool.pen, .line, .arrow, .rectangle, .ellipse, .textBox, .note] {
            XCTAssertEqual(AnnotationStyleDefaults.style(for: AnnotationStyleDefaults.key(tool: tool, highlighter: false)) == nil, false)
        }
        XCTAssertEqual(AnnotationStyleDefaults.style(for: AnnotationStyleDefaults.key(tool: .pen, highlighter: true)) == nil, false)
        XCTAssertFalse(AnnotationTool.eraser.draws)
    }
}

final class ReadingDoesNotDirtyTheDocumentTests: XCTestCase {
    func sampleURL() -> URL? {
        [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/framed-vertical-page.pdf"),
         URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/KongFolioTests/Fixtures/framed-vertical-page.pdf")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @MainActor func testAnOpenedFileIsNotUnsavedWorkEvenWhenItIsRebuiltAsAnEditableCopy() throws {
        guard let url = sampleURL() else { return }
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        space.load([url], prepared: .documents([try Data(contentsOf: url)]))
        XCTAssertEqual(space.count, 1)
        XCTAssertFalse(space.dirty)
        space.selectPage(0)
        XCTAssertFalse(space.dirty)
        // Closing a document that was only read does not ask anything.
        XCTAssertTrue(space.closeDocument())
        XCTAssertEqual(space.count, 0)
    }

    @MainActor func testAnEditMakesItUnsavedWork() throws {
        guard let url = sampleURL() else { return }
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        space.load([url], prepared: .documents([try Data(contentsOf: url)]))
        XCTAssertFalse(space.dirty)
        space.rotate()
        XCTAssertTrue(space.dirty)
    }
}
