import XCTest
import PDFKit
@testable import KongFolio

final class TextImportTests: XCTestCase {
    func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    // A text file becomes an A4 PDF whose text layer can be searched.
    func testPlainTextBecomesSearchableA4() throws {
        let url = try write(Data("學而時習之，不亦說乎？\n有朋自遠方來，不亦樂乎？".utf8), ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try DocumentServices.load(url)
        XCTAssertEqual(doc.pageCount, 1)
        let bounds = doc.page(at: 0)!.bounds(for: .mediaBox)
        XCTAssertEqual(Double(bounds.width), 595.28, accuracy: 0.5)
        XCTAssertEqual(Double(bounds.height), 841.89, accuracy: 0.5)
        XCTAssertTrue(doc.string?.contains("不亦說乎") == true)
        XCTAssertTrue(doc.string?.contains("遠方來") == true)
    }

    func testLongTextPaginatesWithoutLosingLines() throws {
        let text = (1...400).map { "第\($0)行：用于检验分页是否完整的一行文字。" }.joined(separator: "\n")
        let doc = try TextImport.render(text, markdown: false)
        XCTAssertTrue(doc.pageCount > 3)
        XCTAssertTrue(doc.string?.contains("第1行：") == true)
        XCTAssertTrue(doc.string?.contains("第200行：") == true)
        XCTAssertTrue(doc.string?.contains("第400行：") == true)
    }

    func testEncodingDetection() throws {
        let sample = "学而时习之，不亦说乎？"
        XCTAssertEqual(try TextImport.decode(Data(sample.utf8)), sample)
        XCTAssertEqual(try TextImport.decode(Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8)), sample)
        XCTAssertEqual(try TextImport.decode(sample.data(using: .utf16)!), sample)
        XCTAssertEqual(try TextImport.decode(sample.data(using: TextImport.gb18030)!), sample)
    }

    func testEmptyTextIsRejected() throws {
        let url = try write(Data("  \n\n ".utf8), ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DocumentServices.load(url))
    }

    // Markdown markers are interpreted instead of printed.
    func testMarkdownStructure() throws {
        let source = "# 标题\n\n正文 **粗体** 与 *斜体* 与 `代码`\n\n- 项一\n- [x] 项二\n1. 甲\n> 引用\n---\n```\nlet x = 1\n```\n[链接](https://example.com)"
        let text = TextImport.markdown(source).string
        for expected in ["标题", "粗体", "斜体", "代码", "• 项一", "☑ 项二", "1. 甲", "引用", "let x = 1", "链接"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        for marker in ["#", "**", "`", "```", "> ", "[x]", "https://example.com"] {
            XCTAssertFalse(text.contains(marker), marker)
        }
    }

    func testMarkdownFileLoadsAsDocument() throws {
        let url = try write(Data("# 论语\n\n**学而**时习之\n\n- 不亦说乎".utf8), ext: "md")
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try DocumentServices.load(url)
        XCTAssertTrue(doc.string?.contains("学而时习之") == true)
        XCTAssertFalse(doc.string?.contains("**") == true)
        XCTAssertTrue(TextImport.handles(url))
    }

    func testNestedAndOrderedListParsing() throws {
        let nested = TextImport.listItem("    - 子项")
        XCTAssertEqual(nested?.indent, 4); XCTAssertEqual(nested?.text, "子项")
        XCTAssertEqual(TextImport.listItem("12. 十二")?.marker, "12. ")
        XCTAssertNil(TextImport.listItem("2024年报告"))
        XCTAssertNil(TextImport.listItem("-没有空格"))
    }
}
