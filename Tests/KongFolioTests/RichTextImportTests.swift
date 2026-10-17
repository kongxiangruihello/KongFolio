import XCTest
import PDFKit
@testable import KongFolio

final class RichTextImportTests: XCTestCase {
    func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    func sample() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "学而时习之，不亦说乎？\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        text.append(NSAttributedString(string: "Second paragraph for the import test.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        return text
    }

    func testHandlesTheDocumentExtensions() {
        for ext in ["docx", "doc", "rtf", "rtfd", "odt", "html", "HTM"] {
            XCTAssertTrue(RichTextImport.handles(URL(fileURLWithPath: "/tmp/a." + ext)))
        }
        XCTAssertFalse(RichTextImport.handles(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(RichTextImport.handles(URL(fileURLWithPath: "/tmp/a.md")))
    }

    func testRTFBecomesSearchableA4() throws {
        let source = sample()
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = try write(data, ext: "rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try DocumentServices.load(url)
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(Double(document.page(at: 0)!.bounds(for: .mediaBox).width), 595.28, accuracy: 0.5)
        XCTAssertTrue(document.string?.contains("Second paragraph") == true)
        XCTAssertTrue(document.string?.contains("不亦说乎") == true)
    }

    func testDocxBecomesSearchable() throws {
        let source = sample()
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = try write(data, ext: "docx")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try DocumentServices.load(url)
        XCTAssertTrue(document.string?.contains("Second paragraph") == true)
    }

    func testPicturesBecomeAMarkerAndLongTextPaginates() throws {
        let attachment = NSTextAttachment()
        let text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " after"))
        let normalized = RichTextImport.normalize(text)
        XCTAssertTrue(normalized.string.contains(RichTextImport.placeholder))
        XCTAssertFalse(normalized.string.contains("\u{FFFC}"))

        let long = NSAttributedString(string: (1...400).map { "Line \($0) of a long document." }.joined(separator: "\n"))
        let document = try TextImport.pdf(from: RichTextImport.normalize(long))
        XCTAssertTrue(document.pageCount > 3)
        XCTAssertTrue(document.string?.contains("Line 400 of") == true)
    }

    func testHTMLKeepsTextListsAndTablesAndDropsScripts() throws {
        let page = """
        <html><head><title>Hidden title</title><style>p { color: red }</style><script>var secret = 1;</script></head>
        <body><h1>Heading One</h1><p>First <b>bold</b> and <i>italic</i> text.</p>
        <ul><li>Apple</li><li>Pear</li></ul><ol><li>One</li><li>Two</li></ol>
        <table><tr><th>Name</th><th>Qty</th></tr><tr><td>Tea</td><td>3</td></tr></table>
        <p>学而时习之，不亦说乎？</p><img src="a.png" alt="chart"></body></html>
        """
        let text = try RichTextImport.html(Data(page.utf8)).string
        XCTAssertTrue(text.contains("Heading One"))
        XCTAssertTrue(text.contains("First bold and italic text."))
        XCTAssertTrue(text.contains("• Apple"))
        XCTAssertTrue(text.contains("• Pear"))
        XCTAssertTrue(text.contains("1. One"))
        XCTAssertTrue(text.contains("2. Two"))
        XCTAssertTrue(text.contains("Name\tQty"))
        XCTAssertEqual(text.components(separatedBy: "\n").first { $0.hasPrefix("Tea") }, "Tea\t3")
        XCTAssertTrue(text.contains("不亦说乎"))
        XCTAssertTrue(text.contains("［图片：chart］"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("Hidden title"))
        XCTAssertFalse(text.contains("color: red"))
    }

    func testHTMLFileOpensAsADocument() throws {
        let url = try write(Data("<html><body><h2>Title</h2><p>Body text here.</p></body></html>".utf8), ext: "html")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try DocumentServices.load(url)
        XCTAssertTrue(document.string?.contains("Body text here.") == true)
    }

    func testAFileWithoutTextGivesAMessage() throws {
        let empty = try write(Data("<html><body></body></html>".utf8), ext: "html")
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try DocumentServices.load(empty))
    }
}
