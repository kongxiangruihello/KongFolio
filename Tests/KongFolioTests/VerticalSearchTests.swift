import XCTest
import PDFKit
@testable import KongFolio

final class VerticalSearchTests: XCTestCase {
    func column(_ text: String, x: CGFloat, confidence: Float = 0.9) -> [RecognizedLine] {
        text.enumerated().map { RecognizedLine(text: String($1), box: CGRect(x: x, y: 0.9 - CGFloat($0) * 0.05, width: 0.04, height: 0.045), confidence: confidence) }
    }

    func page() -> [RecognizedLine] { column("學而時習之", x: 0.8) + column("不亦說乎", x: 0.7) + column("有朋自遠方來", x: 0.6) }

    func testGlyphsKnowTheirColumns() throws {
        let glyphs = try OrderedText.characters(page()).unwrap("不是竖排")
        XCTAssertEqual(glyphs.map(\.text).joined(), "學而時習之不亦說乎有朋自遠方來")
        XCTAssertEqual(glyphs.map(\.column), [0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2])
        XCTAssertEqual(OrderedText.verticalColumns(page()), ["學而時習之", "不亦說乎", "有朋自遠方來"])
    }

    func testTextOfTheChosenGlyphsIsALinePerColumn() throws {
        let glyphs = try OrderedText.characters(page()).unwrap("不是竖排")
        let text = OrderedText.text(of: glyphs) { "習之不亦".contains($0.text) }
        XCTAssertEqual(text, "習之\n不亦")
        XCTAssertEqual(OrderedText.text(of: glyphs) { _ in false }, "")
    }

    func testFractionsAndPageRectsAreInverse() {
        let crop = CGRect(x: 5, y: 7, width: 200, height: 300)
        let box = CGRect(x: 0.25, y: 0.4, width: 0.1, height: 0.2)
        for rotation in [0, 90, 180, 270] {
            let rect = OrderedText.pageRect(forFraction: box, cropBox: crop, rotation: rotation)
            XCTAssertTrue(crop.contains(rect))
            let back = OrderedText.fraction(ofPageRect: rect, cropBox: crop, rotation: rotation)
            XCTAssertEqual(back.minX, box.minX, accuracy: 0.0001)
            XCTAssertEqual(back.minY, box.minY, accuracy: 0.0001)
            XCTAssertEqual(back.width, box.width, accuracy: 0.0001)
            XCTAssertEqual(back.height, box.height, accuracy: 0.0001)
        }
    }

    func blankBook(pages: Int) -> Data {
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
            document.insert(page, at: index)
        }
        return document.dataRepresentation()!
    }

    func testSearchFindsAPhraseThatRunsAcrossColumnsAndReportsOneStripPerColumn() throws {
        let data = blankBook(pages: 2)
        let within = try ReadingServices.search(data, query: "時習", records: [0: page()])
        XCTAssertEqual(within.count, 1)
        XCTAssertEqual(within[0].page, 0)
        XCTAssertEqual(within[0].strips?.count, 1)
        XCTAssertTrue(within[0].snippet.contains("學而時習之"))

        let across = try ReadingServices.search(data, query: "之不亦", records: [0: page()])
        XCTAssertEqual(across.count, 1)
        XCTAssertEqual(across[0].strips?.count, 2)
        let first = try XCTUnwrapStrip(across[0].strips, 0), second = try XCTUnwrapStrip(across[0].strips, 1)
        XCTAssertTrue(first.minX > second.minX)           // the first column is to the right

        // Simplified characters find traditional ones, as in the rest of the search.
        XCTAssertEqual(try ReadingServices.search(data, query: "学而", records: [0: page()]).count, 1)
        XCTAssertEqual(try ReadingServices.search(data, query: "不存在", records: [0: page()]).count, 0)
        // A page without a record is not searched here (the blank pages have no text layer).
        XCTAssertEqual(try ReadingServices.search(data, query: "學而", records: [:]).count, 0)
    }

    func XCTUnwrapStrip(_ strips: [CGRect]?, _ index: Int) throws -> CGRect {
        try (strips.flatMap { $0.indices.contains(index) ? $0[index] : nil }).unwrap("没有这一段")
    }
}
