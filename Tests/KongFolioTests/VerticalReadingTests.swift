import XCTest
import PDFKit
@testable import KongFolio

final class VerticalReadingTests: XCTestCase {
    /// One recognised character per cell, as the vertical recognition places them: columns from right to left.
    func cells(_ text: String, x: CGFloat, confidence: Float = 0.9) -> [RecognizedLine] {
        text.enumerated().map { index, character in
            RecognizedLine(text: String(character), box: CGRect(x: x, y: 0.9 - CGFloat(index) * 0.05, width: 0.04, height: 0.045), confidence: confidence)
        }
    }

    func page() -> [RecognizedLine] {
        cells("學而時習之", x: 0.8) + cells("不亦說乎", x: 0.7) + [RecognizedLine(text: "有朋自遠方來", box: CGRect(x: 0.6, y: 0.3, width: 0.04, height: 0.6), confidence: 0.4, approximate: true)]
    }

    func testColumnsComeOutRightToLeft() throws {
        let columns = try OrderedText.verticalColumns(page()).unwrap("不是竖排")
        XCTAssertEqual(columns, ["學而時習之", "不亦說乎", "有朋自遠方來"])
    }

    func testHorizontalLinesAreNotTreatedAsVertical() {
        let lines = [RecognizedLine(text: "Hello world", box: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04), confidence: 0.9),
                     RecognizedLine(text: "second line here", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.04), confidence: 0.9)]
        XCTAssertFalse(OrderedText.isVertical(lines))
        XCTAssertNil(OrderedText.verticalColumns(lines))
        XCTAssertNil(OrderedText.verticalColumns([]))
    }

    func testParagraphsFollowTheColumnsOrTheTextLayer() {
        XCTAssertEqual(OrderedText.paragraphs(regions: page(), pageText: "ignored", mergeLines: true, keepColumns: true), ["學而時習之", "不亦說乎", "有朋自遠方來"])
        XCTAssertEqual(OrderedText.paragraphs(regions: page(), pageText: "ignored", mergeLines: true, keepColumns: false), ["學而時習之不亦說乎有朋自遠方來"])
        XCTAssertEqual(OrderedText.paragraphs(regions: nil, pageText: "甲乙。\n丙丁", mergeLines: true, keepColumns: true), ["甲乙。", "丙丁"])
    }

    func testQualityFlagsFewCharactersApproximateColumnsAndLowConfidence() {
        XCTAssertTrue(OCRQuality.assess(page: 0, lines: cells("學而時習之不亦說乎有朋自遠方來", x: 0.8)).reasons.isEmpty)
        XCTAssertEqual(OCRQuality.assess(page: 1, lines: []).reasons, ["没有识别出文字"])
        XCTAssertTrue(OCRQuality.assess(page: 2, lines: cells("學而", x: 0.8)).reasons.first?.contains("很少") == true)
        let mixed = OCRQuality.assess(page: 3, lines: page())
        XCTAssertTrue(mixed.reasons.contains { $0.contains("1 列未能逐字对位") })
        XCTAssertTrue(mixed.reasons.contains { $0.contains("置信度 40%") })
    }

    func testRemappingRegionsAfterACut() {
        let box = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.2)
        XCTAssertEqual(PageCrop.remap(box, from: .zero, to: .zero), box)
        let moved = PageCrop.remap(box, from: .zero, to: CropMargins(left: 0.1, right: 0.1, top: 0.1, bottom: 0.2))
        XCTAssertEqual(moved.minX, 0.5, accuracy: 0.0001)               // (0.5 - 0.1) / 0.8
        XCTAssertEqual(moved.width, 0.125, accuracy: 0.0001)
        XCTAssertEqual(moved.minY, (0.5 - 0.2) / 0.7, accuracy: 0.0001)
        let back = PageCrop.remap(moved, from: CropMargins(left: 0.1, right: 0.1, top: 0.1, bottom: 0.2), to: .zero)
        XCTAssertEqual(back.minX, box.minX, accuracy: 0.0001)
        XCTAssertEqual(back.height, box.height, accuracy: 0.0001)
    }

    @MainActor func workspace(pages: Int) throws -> (Workspace, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        let workspace = Workspace(storage: directory)
        workspace.document = try TextImport.render((1...pages).map { _ in "ZZZ" }.joined(separator: "\n\u{0C}\n"), markdown: false)
        let blank = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
            blank.insert(page, at: index)
        }
        workspace.document = PDFDocument(data: blank.dataRepresentation()!)!
        return (workspace, directory)
    }

    @MainActor func testCroppingKeepsTheRecognitionRecordOnItsCharacters() throws {
        let (workspace, directory) = try workspace(pages: 2); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.updateMeta(0) { $0.ocrRegions = self.page() }
        workspace.cropOdd = CropMargins(left: 0.1, right: 0.1, top: 0.1, bottom: 0.1)
        workspace.cropScope = .all
        workspace.applyCrop()
        let cut = try workspace.meta(0).ocrRegions.unwrap("识别记录丢失")
        XCTAssertEqual(cut.count, page().count)
        XCTAssertEqual(cut[0].box.minX, (0.8 - 0.1) / 0.8, accuracy: 0.0001)
        XCTAssertEqual(OrderedText.verticalColumns(cut), ["學而時習之", "不亦說乎", "有朋自遠方來"])
        workspace.cropScope = .all
        workspace.resetCrop()
        XCTAssertEqual(try workspace.meta(0).ocrRegions.unwrap("识别记录丢失")[0].box.minX, 0.8, accuracy: 0.0001)
    }

    @MainActor func testTheQualityReportListsOnlyDoubtfulPagesWithARecord() throws {
        let (workspace, directory) = try workspace(pages: 3); defer { try? FileManager.default.removeItem(at: directory) }
        workspace.updateMeta(0) { $0.ocrRegions = self.cells("學而時習之不亦說乎有朋自遠方來", x: 0.8) }
        workspace.updateMeta(1) { $0.ocrRegions = self.page() }
        let report = workspace.ocrQualityReport()
        XCTAssertEqual(report.checked, 2)
        XCTAssertEqual(report.doubtful.map(\.page), [1])
    }

    func testWordExportReadsVerticalPagesInColumnOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try TextImport.render("ZZZ", markdown: false)
        var options = WordExportOptions()
        options.content = .textOnly
        options.pageMarks = false
        let merged = directory.appendingPathComponent("a.docx")
        _ = try WordExport.write(document, pages: [0], outline: [], options: options, regions: [0: page()], to: merged)
        let xml = try unzip(["-p", merged.path, "word/document.xml"])
        XCTAssertTrue(xml.contains("學而時習之不亦說乎有朋自遠方來"))
        XCTAssertFalse(xml.contains("ZZZ"))
        options.keepColumns = true
        let columns = directory.appendingPathComponent("b.docx")
        _ = try WordExport.write(document, pages: [0], outline: [], options: options, regions: [0: page()], to: columns)
        let split = try unzip(["-p", columns.path, "word/document.xml"])
        XCTAssertTrue(split.contains(">學而時習之<"))
        XCTAssertTrue(split.contains(">不亦說乎<"))
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
}
