import XCTest
import PDFKit
@testable import KongFolio

final class OCRAccuracyTests: XCTestCase {
    func testIdenticalTextHasNoErrorsAndPunctuationIsIgnored() {
        let result = OCRAccuracy.compare(reference: "昨閱西報，得悉俄國。", recognized: "昨閱西報得悉俄國")
        XCTAssertEqual(result.edits, 0)
        XCTAssertEqual(result.accuracy, 1, accuracy: 0.0001)
    }

    func testSubstitutionsInsertionsAndDeletionsEachCountOnce() {
        XCTAssertEqual(OCRAccuracy.compare(reference: "大美國", recognized: "大羙國").edits, 1)
        XCTAssertEqual(OCRAccuracy.compare(reference: "大美國", recognized: "大美美國").edits, 1)
        XCTAssertEqual(OCRAccuracy.compare(reference: "大美國", recognized: "大國").edits, 1)
        let result = OCRAccuracy.compare(reference: "一二三四", recognized: "一三五四")
        XCTAssertEqual(result.edits, 2)
        XCTAssertEqual(result.errorRate, 0.5, accuracy: 0.0001)
    }

    func testEmptyInputsDoNotDivideByZero() {
        XCTAssertEqual(OCRAccuracy.compare(reference: "", recognized: "").errorRate, 0, accuracy: 0.0001)
        XCTAssertEqual(OCRAccuracy.compare(reference: "", recognized: "字").errorRate, 1, accuracy: 0.0001)
        XCTAssertEqual(OCRAccuracy.compare(reference: "字字", recognized: "").accuracy, 0, accuracy: 0.0001)
    }

    /// Prints the measured rate on the real page (see the failure text on CI) against a hand transcription.
    func testTheRealPageAccuracyIsMeasured() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/KongFolioTests/Fixtures")
        guard let folder = [directory, fallback].first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("framed-vertical-page.pdf").path) }),
              DocumentServices.supportedOCRLanguages.contains("zh-Hant"),
              let document = PDFDocument(url: folder.appendingPathComponent("framed-vertical-page.pdf")),
              let page = document.page(at: 0),
              let reference = try? String(contentsOf: folder.appendingPathComponent("framed-vertical-page.txt"), encoding: .utf8) else { return }
        let image = try DocumentServices.withoutRedMarks(DocumentServices.render(page, maxDimension: 3000))
        let lines = try VerticalText.recognize(image, languages: ["zh-Hant", "en-US"])
        let result = OCRAccuracy.compare(reference: reference, recognized: OCRAccuracy.readingText(of: lines))
        XCTAssertEqual(-1, Int((result.accuracy * 100).rounded()), "准确率 \(result.accuracy) 编辑距离 \(result.edits) 参考 \(result.referenceCount) 识别 \(result.recognizedCount)")
    }
}
