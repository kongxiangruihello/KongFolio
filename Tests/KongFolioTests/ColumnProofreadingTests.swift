import XCTest
import PDFKit
@testable import KongFolio

final class ColumnProofreadingTests: XCTestCase {
    /// Two columns of three characters each, one RecognizedLine per character, right column first.
    private func page() -> [RecognizedLine] {
        var lines: [RecognizedLine] = []
        for (x, text) in [(0.7, "天地玄"), (0.4, "宇宙洪")] {
            for (row, character) in text.enumerated() {
                lines.append(RecognizedLine(text: String(character), box: CGRect(x: x, y: 0.8 - Double(row) * 0.1, width: 0.05, height: 0.08), confidence: x > 0.5 ? 0.9 : 0.3))
            }
        }
        return lines
    }

    func testColumnsReadRightToLeftWithTheirConfidence() throws {
        let columns = try XCTUnwrap(ColumnProofreading.columns(page()))
        XCTAssertEqual(columns.map(\.text), ["天地玄", "宇宙洪"])
        XCTAssertEqual(columns.map { $0.isDoubtful(below: ColumnProofreading.doubtfulThreshold) }, [false, true])
        XCTAssertTrue(columns[0].perCharacter)
        XCTAssertEqual(columns[0].pieces.count, 3)
    }

    func testUntouchedColumnsKeepTheirRecords() throws {
        let columns = try XCTUnwrap(ColumnProofreading.columns(page()))
        XCTAssertEqual(ColumnProofreading.lines(from: columns).map(\.text), page().map(\.text))
        XCTAssertEqual(ColumnProofreading.changes(in: columns).edits, 0)
    }

    func testSameLengthCorrectionKeepsPositionsAndMarksSure() throws {
        var columns = try XCTUnwrap(ColumnProofreading.columns(page()))
        columns[1].text = "宇宙洪"
        columns[1].text = "宇宙鴻"
        let lines = ColumnProofreading.lines(from: columns)
        XCTAssertEqual(lines.map(\.text).joined(), "天地玄宇宙鴻")
        XCTAssertEqual(lines.last?.box, page().last?.box)
        XCTAssertEqual(lines.last?.confidence, 1)
        XCTAssertEqual(ColumnProofreading.changes(in: columns).edits, 1)
    }

    func testChangedLengthBecomesOnePieceOverTheColumn() throws {
        var columns = try XCTUnwrap(ColumnProofreading.columns(page()))
        columns[0].text = "天地玄黃"
        let lines = ColumnProofreading.lines(from: columns)
        let first = try XCTUnwrap(lines.first)
        XCTAssertEqual(first.text, "天地玄黃")
        XCTAssertEqual(first.approximate, true)
        // The page still reads as a vertical page, so search and copying keep working.
        XCTAssertEqual(OrderedText.verticalColumns(lines), ["天地玄黃", "宇宙洪"])
    }

    func testEmptiedColumnIsDropped() throws {
        var columns = try XCTUnwrap(ColumnProofreading.columns(page()))
        columns[0].text = " \n"
        XCTAssertEqual(OrderedText.verticalColumns(ColumnProofreading.lines(from: columns)), ["宇宙洪"])
    }

    func testApproximateColumnsAreProofreadAsWholeColumns() throws {
        let lines = [RecognizedLine(text: "天地玄黃", box: CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.8), confidence: 0.4, approximate: true),
                     RecognizedLine(text: "宇宙洪荒", box: CGRect(x: 0.4, y: 0.1, width: 0.1, height: 0.8), confidence: 0.9, approximate: true)]
        var columns = try XCTUnwrap(ColumnProofreading.columns(lines))
        XCTAssertEqual(columns.map(\.text), ["天地玄黃", "宇宙洪荒"])
        columns[0].text = "天地玄黄"
        XCTAssertEqual(ColumnProofreading.lines(from: columns).map(\.text), ["天地玄黄", "宇宙洪荒"])
    }

    func testCropRectIsTopLeftOriginAndStaysInsideThePicture() {
        let rect = ColumnProofreading.cropRect(box: CGRect(x: 0.9, y: 0.0, width: 0.1, height: 0.2), imageSize: CGSize(width: 1000, height: 2000), padding: 0.02)
        XCTAssertEqual(rect.maxX, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.maxY, 2000, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 2000 * (1 - 0.22), accuracy: 0.01)
    }

    @MainActor func testApplyWithoutOriginalPageUpdatesRecords() throws {
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0)
        space.document = doc
        space.updateMeta(0) { $0.ocrRegions = page() }
        var columns = try XCTUnwrap(ColumnProofreading.columns(page()))
        columns[1].text = "宇宙鴻"
        XCTAssertTrue(space.applyProofreading(columns, page: 0))
        XCTAssertEqual(OrderedText.verticalColumns(space.meta(0).ocrRegions ?? []), ["天地玄", "宇宙鴻"])
    }
}
