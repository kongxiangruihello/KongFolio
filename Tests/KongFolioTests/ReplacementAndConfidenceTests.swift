import XCTest
import PDFKit
@testable import KongFolio

final class ReplacementAndConfidenceTests: XCTestCase {
    func testRulesAreReadOnePerLine() {
        let rules = ReplacementRules.parse("# 常见误识\n戌=戊\n已 → 己\n巳->己\n\n删除我=\n  \n=没有左边\n没有等号的行")
        XCTAssertEqual(rules, [ReplacementRule(from: "戌", to: "戊"), ReplacementRule(from: "已", to: "己"), ReplacementRule(from: "巳", to: "己"), ReplacementRule(from: "删除我", to: "")])
    }

    func testRulesApplyInOrderOverTheWholeText() {
        let rules = ReplacementRules.parse("甲=乙\n乙=丙\n垃圾=")
        XCTAssertEqual(ReplacementRules.apply(rules, to: "甲垃圾甲"), "丙丙")
        XCTAssertEqual(ReplacementRules.apply([], to: "不变"), "不变")
    }

    func column(_ text: String, x: CGFloat, confidence: Float) -> [RecognizedLine] {
        text.enumerated().map { RecognizedLine(text: String($1), box: CGRect(x: x, y: 0.9 - CGFloat($0) * 0.05, width: 0.04, height: 0.045), confidence: confidence) }
    }

    func testDoubtfulColumnsAreFoundByTheirLowestConfidence() throws {
        let lines = column("學而時習之", x: 0.8, confidence: 0.9) + column("不亦說乎", x: 0.7, confidence: 0.3) + column("有朋自遠方來", x: 0.6, confidence: 0.49)
        let glyphs = try OrderedText.characters(lines).unwrap("不是竖排")
        XCTAssertEqual(glyphs[5].confidence, 0.3, accuracy: 0.001)
        let boxes = OrderedText.doubtfulColumns(glyphs, threshold: 0.5)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].minX, 0.7, accuracy: 0.0001)                 // the second column, as one box
        XCTAssertEqual(boxes[0].height, 0.045 + 3 * 0.05, accuracy: 0.0001)
        XCTAssertEqual(OrderedText.doubtfulColumns(glyphs, threshold: 0.2).count, 0)
    }

    func testWordExportAppliesTheRulesToTheText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try TextImport.render("占位", markdown: false)
        var options = WordExportOptions()
        options.content = .textOnly
        options.pageMarks = false
        options.replacements = ReplacementRules.parse("說=説")
        let target = directory.appendingPathComponent("a.docx")
        _ = try WordExport.write(document, pages: [0], outline: [], options: options, regions: [0: column("學而時習之", x: 0.8, confidence: 0.9) + column("不亦說乎", x: 0.7, confidence: 0.9)], to: target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", target.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertTrue(xml.contains("學而時習之不亦説乎"))
        XCTAssertFalse(xml.contains("說"))
    }
}
