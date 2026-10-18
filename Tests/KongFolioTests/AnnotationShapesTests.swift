import XCTest
import PDFKit
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
