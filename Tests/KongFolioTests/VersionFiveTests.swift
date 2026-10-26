import XCTest
import PDFKit
import AppKit
@testable import KongFolio

final class VersionFiveTests: XCTestCase {
    let columns = ["學而時習之", "不亦說乎有", "朋自遠方來"]

    /// A one-page PDF made from a synthetic vertical page, OCR'd in vertical mode.
    func verticalOCR() throws -> JobResult {
        let image = VersionFourTests().verticalPage(columns)
        let page = try XCTUnwrapPage(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))))
        let doc = PDFDocument(); doc.insert(page, at: 0)
        var settings = OCRSettings(); settings.languages = ["zh-Hant", "zh-Hans"]; settings.vertical = true
        return try BackgroundJobs.run(JobSpec(operation: .ocr, source: doc.dataRepresentation()!, pages: [0], revision: UUID(), ocr: settings)) { _ in }
    }

    func XCTUnwrapPage(_ page: PDFPage?) throws -> PDFPage {
        guard let page else { throw FolioError(message: "missing page") }
        return page
    }

    func cleaned(_ text: String?) -> String { ReadingServices.repairIdeographs(text ?? "").filter { !$0.isWhitespace } }

    func testVerticalLinesCarryColumnsRightToLeft() throws {
        let lines = try verticalOCR().regions[0]!
        XCTAssertEqual(Set(lines.compactMap(\.column)), [0, 1, 2])
        let ordered = try XCTUnwrapText(ReadingOrder.text(lines))
        print("probe: reading order text = [\(ordered.replacingOccurrences(of: "\n", with: "｜"))]")
        XCTAssertEqual(ordered.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(cleaned(ordered).hasPrefix("學而時習之"), "reading order: \(ordered)")
        // The rightmost column comes first and sits to the right of the last one.
        let first = lines.first { $0.column == 0 }!, last = lines.first { $0.column == 2 }!
        XCTAssertTrue(first.box.minX > last.box.maxX)
    }

    func XCTUnwrapText(_ text: String?) throws -> String {
        guard let text else { throw FolioError(message: "missing text") }
        return text
    }

    // A phrase that runs from the bottom of one column to the top of the next is found, highlighted
    // on the right characters, and stays correct after the page is rotated in all four directions.
    @MainActor func testCrossColumnSearchSelectionAndRotation() throws {
        let result = try verticalOCR()
        let w = Workspace(); w.document = PDFDocument(data: result.pdf!)!
        w.updateMeta(0) { $0.ocrOriginal = result.originals[0]; $0.ocrRegions = result.regions[0] }
        let pageOrder = cleaned(w.document.page(at: 0)!.string)
        print("probe: PDFKit page.string order = [\(pageOrder)]")
        XCTAssertEqual(try ReadingServices.search(try w.pdfData(), query: "乎有朋").count, 0, "PDFKit order should not contain the cross-column phrase")
        for turn in 0..<4 {
            let hits = try ReadingServices.search(try w.pdfData(), query: "乎有朋", ordered: w.orderedOCRLines())
            XCTAssertEqual(hits.count, 1, "rotation \(turn * 90)")
            guard let hit = hits.first else { break }
            XCTAssertEqual(hit.boxes.count, 3)
            let selected = cleaned(ReadingOrder.selection(for: hit.boxes, on: w.page!)?.string)
            print("probe: rotation \(w.page!.rotation) selection = [\(selected)]")
            XCTAssertEqual(Set(selected), Set("乎有朋"), "rotation \(w.page!.rotation): selected \(selected)")
            // Simplified query against the traditional text, also across the column break.
            XCTAssertEqual(try ReadingServices.search(try w.pdfData(), query: "习之不亦说", ordered: w.orderedOCRLines()).count, 1)
            w.rotate()
        }
    }

    @MainActor func testExportUsesColumnOrder() throws {
        let result = try verticalOCR()
        let w = Workspace(); w.document = PDFDocument(data: result.pdf!)!
        // Inspection-only regions (no OCR original) do not override the PDF text.
        w.updateMeta(0) { $0.ocrRegions = result.regions[0] }
        XCTAssertTrue(w.orderedOCRLines().isEmpty)
        w.updateMeta(0) { $0.ocrOriginal = result.originals[0] }
        let text = w.fullText(markdown: true)
        XCTAssertTrue(text.hasPrefix("## 第 1 页\n\n"))
        let body = cleaned(text.replacingOccurrences(of: "## 第 1 页", with: ""))
        XCTAssertTrue(body.hasPrefix("學而時習之"), "export: \(body)")
        XCTAssertTrue(body.contains("乎有朋"))
    }

    // The upright-box → page-space mapping matches PDFKit for every rotation.
    func testPageRectMappingForAllRotations() throws {
        let base = DocumentServicesTests().fixture().page(at: 0)!
        let line = RecognizedLine(text: "學", box: CGRect(x: 0.7, y: 0.7, width: 0.12, height: 0.09), column: 0)
        let page = try DocumentServices.searchablePage(base, lines: [line])
        let doc = PDFDocument(); doc.insert(page, at: 0)
        var stored = line
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let selected = cleaned(ReadingOrder.selection(for: [stored.box], on: page)?.string)
            XCTAssertEqual(selected, "學", "rotation \(rotation)")
            stored = stored.rotatedClockwise()
        }
    }
}
