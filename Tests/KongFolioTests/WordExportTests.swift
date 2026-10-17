import XCTest
import PDFKit
@testable import KongFolio

final class WordExportTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func unzip(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func book() throws -> PDFDocument {
        try TextImport.render((1...120).map { "第\($0)行：学而时习之，不亦说乎？" }.joined(separator: "\n"), markdown: false)
    }

    func testCRCMatchesTheKnownCheckValue() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    func testLinesBecomeParagraphsAtSentenceEnds() {
        let text = "学而时习之，\n不亦说乎？\n有朋自远方来，\n不亦乐乎？\n\nHello\nworld.\nNext"
        XCTAssertEqual(WordExport.paragraphs(from: text, merge: true), ["学而时习之，不亦说乎？", "有朋自远方来，不亦乐乎？", "Hello world.", "Next"])
        XCTAssertEqual(WordExport.paragraphs(from: "甲\n乙\n\n丙", merge: false), ["甲", "乙", "丙"])
        XCTAssertEqual(WordExport.paragraphs(from: "  \n \n", merge: true), [])
    }

    func testXMLIsEscapedAndControlCharactersDropped() {
        XCTAssertEqual(WordExport.escape("a & b < c > d"), "a &amp; b &lt; c &gt; d")
        XCTAssertEqual(WordExport.escape("甲\u{0}乙\u{8}丙\n丁"), "甲乙丙 丁")
    }

    func testTheFileIsAValidZipWithTextPicturesAndHeadings() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = try book()
        XCTAssertTrue(document.pageCount >= 2)
        let target = directory.appendingPathComponent("书.docx")
        let outline = [OutlineEntry(page: 0, label: "第一编 <总论>", depth: 0), OutlineEntry(page: 1, label: "第一章", depth: 1)]
        let report = try WordExport.write(document, pages: Array(0..<document.pageCount), outline: outline, options: WordExportOptions(), to: target)
        XCTAssertEqual(report.pages, document.pageCount)
        XCTAssertEqual(report.pictures, document.pageCount)
        XCTAssertTrue(report.characters > 500)
        XCTAssertTrue(report.bytes > 1000)

        XCTAssertTrue(try unzip(["-t", target.path]).contains("No errors detected"))
        let listing = try unzip(["-l", target.path])
        XCTAssertTrue(listing.contains("word/document.xml"))
        XCTAssertTrue(listing.contains("word/media/page-0001.jpg"))
        let xml = try unzip(["-p", target.path, "word/document.xml"])
        XCTAssertTrue(xml.contains("第1行：学而时习之，不亦说乎？"))
        XCTAssertTrue(xml.contains("第一编 &lt;总论&gt;"))
        XCTAssertTrue(xml.contains("Heading1"))
        XCTAssertTrue(xml.contains("Heading2"))
        XCTAssertTrue(xml.contains("—— 第 2 页 ——"))
        XCTAssertEqual(xml.components(separatedBy: "<w:drawing>").count - 1, document.pageCount)
        XCTAssertTrue(try unzip(["-p", target.path, "word/_rels/document.xml.rels"]).contains("media/page-0002.jpg"))
    }

    func testTextOnlyAndPicturesOnly() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = try book()
        var options = WordExportOptions()
        options.content = .textOnly
        options.pageMarks = false
        let textOnly = directory.appendingPathComponent("text.docx")
        let textReport = try WordExport.write(document, pages: [0], outline: [], options: options, to: textOnly)
        XCTAssertEqual(textReport.pictures, 0)
        XCTAssertFalse(try unzip(["-l", textOnly.path]).contains("word/media"))
        let textXML = try unzip(["-p", textOnly.path, "word/document.xml"])
        XCTAssertFalse(textXML.contains("<w:drawing>"))
        XCTAssertFalse(textXML.contains("第 1 页"))

        options.content = .imagesOnly
        let pictures = directory.appendingPathComponent("pictures.docx")
        let pictureReport = try WordExport.write(document, pages: [0, 1], outline: [], options: options, to: pictures)
        XCTAssertEqual(pictureReport.pictures, 2)
        XCTAssertEqual(pictureReport.characters, 0)
        XCTAssertFalse(try unzip(["-p", pictures.path, "word/document.xml"]).contains("学而时习之"))
    }

    func testTheJobReplacesAnExistingFileAndReportsWhatItDid() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = try book()
        let target = directory.appendingPathComponent("out.docx")
        try Data("old".utf8).write(to: target)
        let spec = JobSpec(operation: .word, source: document.dataRepresentation()!, pages: [0], destination: target, revision: UUID(), word: WordExportOptions(), outline: [])
        let result = try BackgroundJobs.run(spec) { _ in }
        XCTAssertTrue(result.message.contains("已导出 1 页"))
        XCTAssertTrue(try unzip(["-t", target.path]).contains("No errors detected"))
        // No staging file is left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }.count, 0)
    }
}
