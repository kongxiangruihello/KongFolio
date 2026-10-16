import XCTest
import PDFKit
@testable import KongFolio

final class StampingTests: XCTestCase {
    /// PDFKit's text extraction does not keep spacing around CJK and digits reliably, so compare without spaces.
    func compact(_ text: String?) -> String { (text ?? "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") }

    func longText() throws -> PDFDocument {
        try TextImport.render((1...400).map { "第\($0)行：用于检验页码的一行文字。" }.joined(separator: "\n"), markdown: false)
    }

    func testInactiveWhenEmpty() {
        XCTAssertFalse(StampOptions().isActive)
        XCTAssertFalse(StampOptions(header: "  \n", footer: " ", watermark: "").isActive)
        XCTAssertTrue(StampOptions(numberFormat: .plain).isActive)
        XCTAssertTrue(StampOptions(watermark: "草稿").isActive)
    }

    func testNumberText() {
        XCTAssertNil(Stamping.numberText(.none, number: 1, last: 9))
        XCTAssertEqual(Stamping.numberText(.plain, number: 3, last: 9), "3")
        XCTAssertEqual(Stamping.numberText(.chinese, number: 3, last: 9), "第 3 页")
        XCTAssertEqual(Stamping.numberText(.ofTotal, number: 3, last: 9), "3 / 9")
    }

    // The original text stays in the page and the stamps become real, searchable text.
    func testStampsAreAddedAndOriginalTextIsKept() throws {
        let source = try longText()
        let stamp = StampOptions(numberFormat: .chinese, header: "页眉文字", footer: "页脚文字")
        let output = try Stamping.apply(stamp, to: source, pages: [0])
        XCTAssertEqual(output.pageCount, 1)
        let text = compact(output.string)
        XCTAssertTrue(text.contains("第1行："))
        XCTAssertTrue(text.contains("第1页"), text.suffix(120).description)
        XCTAssertTrue(text.contains("页眉文字"))
        XCTAssertTrue(text.contains("页脚文字"))
    }

    func testWatermarkIsDrawn() throws {
        let output = try Stamping.apply(StampOptions(watermark: "内部资料"), to: try longText(), pages: [0])
        XCTAssertTrue(compact(output.string).contains("内部资料"))
    }

    func testNumbersFollowStartAndSelection() throws {
        let source = try longText()
        XCTAssertTrue(source.pageCount >= 7)
        let output = try Stamping.apply(StampOptions(numberFormat: .ofTotal, startNumber: 5), to: source, pages: [2, 3, 4])
        XCTAssertEqual(output.pageCount, 3)
        XCTAssertTrue(compact(output.page(at: 0)?.string).contains("5/7"))
        XCTAssertTrue(compact(output.page(at: 2)?.string).contains("7/7"))
    }

    func testPageSizeAndRotationAreKept() throws {
        let fixture = DocumentServicesTests().fixture()
        fixture.page(at: 1)!.rotation = 90
        let committed = try PDFDocument(data: fixture.dataRepresentation().unwrap("序列化失败")).unwrap("读取失败")
        let output = try Stamping.apply(StampOptions(numberFormat: .plain), to: committed, pages: [0, 1])
        let flat = output.page(at: 0)!.bounds(for: .mediaBox), turned = output.page(at: 1)!.bounds(for: .mediaBox)
        XCTAssertEqual(Double(flat.width), 300, accuracy: 0.5); XCTAssertEqual(Double(flat.height), 400, accuracy: 0.5)
        XCTAssertEqual(Double(turned.width), 400, accuracy: 0.5); XCTAssertEqual(Double(turned.height), 300, accuracy: 0.5)
    }

    func testOutlineIsCarriedOver() throws {
        let source = DocumentServicesTests().fixture()
        ReadingServices.applyOutline([OutlineEntry(page: 1, label: "第二页", depth: 0, point: nil), OutlineEntry(page: 2, label: "第三页", depth: 0, point: nil)], to: source)
        let output = try Stamping.apply(StampOptions(numberFormat: .plain), to: source, pages: [1, 2])
        let entries = ReadingServices.outline(output)
        XCTAssertEqual(entries.map(\.label), ["第二页", "第三页"])
        XCTAssertEqual(entries.map(\.page), [0, 1])
    }

    func testExportWithStampWritesStampedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("out.pdf")
        var options = ExportOptions(); options.stamp = StampOptions(numberFormat: .chinese)
        let source = DocumentServicesTests().fixture().dataRepresentation()!
        let spec = JobSpec(operation: .configured, source: source, pages: [0, 1, 2], destination: target, revision: UUID(), exportOptions: options)
        let result = try BackgroundJobs.run(spec) { _ in }
        XCTAssertTrue(result.message.contains("页码"))
        let text = compact(PDFDocument(url: target)?.string)
        XCTAssertTrue(text.contains("第1页")); XCTAssertTrue(text.contains("第3页"))
        let estimate = try ExportServices.estimate(data: source, pages: [0, 1, 2], options: options)
        XCTAssertTrue(estimate.bytes > 0)
    }
}
