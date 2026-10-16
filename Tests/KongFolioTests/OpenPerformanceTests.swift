import XCTest
import PDFKit
@testable import KongFolio

final class OpenPerformanceTests: XCTestCase {
    func temporaryURL(_ ext: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext) }

    // Opening a PDF must not rewrite it: the imported bytes are the file's bytes.
    func testPDFImportKeepsFileBytes() throws {
        let original = DocumentServicesTests().fixture().dataRepresentation()!
        let url = temporaryURL("pdf"); try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .documents(let documents) = try ImportServices.read([url]) else { return XCTAssertTrue(false, "expected documents") }
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0], original)
        XCTAssertEqual(PDFDocument(data: documents[0])?.pageCount, 3)
    }

    func testBrokenPDFIsRejected() throws {
        let url = temporaryURL("pdf"); try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ImportServices.read([url]))
    }

    // Images and text still go through conversion to PDF.
    func testTextImportStillConvertsToPDF() throws {
        let url = temporaryURL("txt"); try Data("你好，世界".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .documents(let documents) = try ImportServices.read([url]) else { return XCTAssertTrue(false, "expected documents") }
        XCTAssertTrue(PDFDocument(data: documents[0])?.string?.contains("你好") == true)
    }
}
