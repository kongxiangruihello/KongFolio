import XCTest
import PDFKit
@testable import KongFolio

/// A real page of a late-Qing book (one page, supplied by the app's user): vertical text in a printed frame with a
/// dark bar at the side, rules along the top and bottom, a faint red seal and a text layer holding only the headings.
/// These tests keep the page-analysis code honest against something that is not synthetic.
final class RealPageTests: XCTestCase {
    func sample() throws -> PDFDocument? {
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/framed-vertical-page.pdf"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/KongFolioTests/Fixtures/framed-vertical-page.pdf"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        let document = try PDFDocument(url: url).unwrap("无法读取样张")
        XCTAssertFalse(document.isLocked)
        XCTAssertEqual(document.pageCount, 1)
        return document
    }

    func testTheContentBoundsFollowThePrintedFrame() throws {
        guard let document = try sample() else { return }
        let page = try document.page(at: 0).unwrap("无页面")
        let bitmap = try ContentBounds.render(page).unwrap("渲染失败")
        let found = try ContentBounds.margins(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height).unwrap("没有找到内容")
        // Measured on this page: left 9 %, top 14 %, bottom 2.5 % (the frame), right close to the edge.
        XCTAssertTrue(found.left > 0.05 && found.left < 0.14)
        XCTAssertTrue(found.top > 0.10 && found.top < 0.19)
        XCTAssertTrue(found.bottom < 0.08)
        XCTAssertTrue(found.right < 0.08)
    }

    func testTheColumnsAreFoundDespiteTheFrame() throws {
        guard let document = try sample() else { return }
        let page = try document.page(at: 0).unwrap("无页面")
        let image = try DocumentServices.render(page, maxDimension: 3000)
        let columns = VerticalText.layout(try VerticalText.Gray(image))
        // The page has about fifteen columns (headings and their notes share a column).
        XCTAssertTrue(columns.count >= 12 && columns.count <= 18)
        XCTAssertTrue((columns.map(\.cells.count).max() ?? 0) >= 35)
        // The faint seal is not ink, so taking red out changes nothing about the columns.
        let withoutRed = VerticalText.layout(try VerticalText.Gray(DocumentServices.withoutRedMarks(image)))
        XCTAssertEqual(withoutRed.count, columns.count)
    }

    func testRecognisingTheWholePageReadsTheHeadings() throws {
        guard let document = try sample(), DocumentServices.supportedOCRLanguages.contains("zh-Hant") else { return }
        let page = try document.page(at: 0).unwrap("无页面")
        let image = try DocumentServices.withoutRedMarks(DocumentServices.render(page, maxDimension: 3000))
        let lines = try VerticalText.recognize(image, languages: ["zh-Hant", "en-US"])
        let columns = try OrderedText.verticalColumns(lines).unwrap("识别结果不是竖排")
        let text = columns.joined()
        XCTAssertTrue(columns.count >= 8)
        XCTAssertTrue(text.count >= 100)
        // Seven headings of the page end in 國.
        XCTAssertTrue(text.filter { $0 == "國" || $0 == "国" }.count >= 3)
    }
}
