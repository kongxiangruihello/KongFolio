import XCTest
import PDFKit
@testable import KongFolio

final class OutlineDetectTests: XCTestCase {
    func testHeadingsAreRecognised() throws {
        XCTAssertEqual(OutlineDetect.heading(in: "卷之一")?.depth, 0)
        XCTAssertEqual(OutlineDetect.heading(in: "卷十二 論語")?.title, "卷十二 論語")
        XCTAssertEqual(OutlineDetect.heading(in: "第三章 緒論")?.depth, 1)
        XCTAssertEqual(OutlineDetect.heading(in: "第二篇")?.depth, 0)
        XCTAssertEqual(OutlineDetect.heading(in: "　凡例　")?.title, "凡例")
        XCTAssertEqual(OutlineDetect.heading(in: "卷１５")?.depth, 0)
        XCTAssertNil(OutlineDetect.heading(in: "卷軸甚多"))                       // 卷 not followed by a number
        XCTAssertNil(OutlineDetect.heading(in: "序言甚長的一段話"))                // 序 only counts on a line of its own
        XCTAssertNil(OutlineDetect.heading(in: "中八月初六日倫敦發來電音"))
        XCTAssertNil(OutlineDetect.heading(in: "  "))
        XCTAssertEqual(OutlineDetect.heading(in: String(repeating: "甲", count: 0) + "卷一" + String(repeating: "乙", count: 50))?.title.count, 30)
    }

    func testCandidatesComeFromTheFirstLinesAndSkipRunningTitles() {
        let pages: [(page: Int, lines: [String])] = [
            (0, ["序", "某年某月"]), (1, ["正文"]), (4, ["卷之一", "正文"]), (5, ["卷之一", "正文"]),       // 5: a running title
            (9, ["正文", "正文", "正文", "卷之二"]),                                                         // too far down the page
            (12, ["正文", "卷之二"]), (20, ["第一章 緒論"]),
        ]
        let found = OutlineDetect.candidates(pages: pages)
        XCTAssertEqual(found.map(\.title), ["序", "卷之一", "卷之二", "第一章 緒論"])
        XCTAssertEqual(found.map(\.page), [0, 4, 12, 20])
        XCTAssertEqual(found.map(\.depth), [0, 0, 0, 1])
    }

    func testMergingKeepsPageOrderAndNeverDuplicates() {
        let existing = [OutlineEntry(page: 10, label: "卷之一", depth: 0), OutlineEntry(page: 30, label: "跋", depth: 0)]
        let chosen = [OutlineCandidate(page: 10, title: "卷之一", depth: 0), OutlineCandidate(page: 2, title: "序", depth: 0),
                      OutlineCandidate(page: 11, title: "第一章", depth: 3)]
        let merged = OutlineDetect.merged(existing, adding: chosen)
        XCTAssertEqual(merged.map(\.label), ["序", "卷之一", "第一章", "跋"])
        XCTAssertEqual(merged.map(\.depth), [0, 0, 1, 0])
    }

    @MainActor func workspace(text: String) throws -> (Workspace, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        let workspace = Workspace(storage: directory)
        workspace.document = try TextImport.render(text, markdown: false)
        return (workspace, directory)
    }

    @MainActor func testTheTextLayerIsUsedForPagesWithoutARecord() throws {
        let (workspace, directory) = try workspace(text: "序\n正文第一行。\n" + (1...150).map { "第\($0)行：用来占满页面的文字。" }.joined(separator: "\n") + "\n卷之二\n后面的正文。")
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.findOutlineCandidates()
        XCTAssertTrue(workspace.showOutlineCandidates)
        XCTAssertTrue(workspace.outlineCandidates.contains { $0.title == "序" && $0.page == 0 })
        workspace.addChosenOutlineCandidates()
        XCTAssertEqual(workspace.outlineEntries.first?.label, "序")
        let saved = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取")
        XCTAssertEqual(ReadingServices.outline(saved).first?.label, "序")
    }

    @MainActor func testVerticalPagesUseTheirRightmostColumns() throws {
        let (workspace, directory) = try workspace(text: "无关的文字")
        defer { try? FileManager.default.removeItem(at: directory) }
        func column(_ text: String, x: CGFloat) -> [RecognizedLine] {
            text.enumerated().map { RecognizedLine(text: String($1), box: CGRect(x: x, y: 0.9 - CGFloat($0) * 0.05, width: 0.04, height: 0.045), confidence: 0.9) }
        }
        workspace.updateMeta(0) { $0.ocrRegions = column("卷之三", x: 0.85) + column("學而時習之", x: 0.75) }
        XCTAssertEqual(workspace.openingLines(of: 0), ["卷之三", "學而時習之"])
        workspace.findOutlineCandidates()
        XCTAssertEqual(workspace.outlineCandidates.map(\.title), ["卷之三"])
    }
}
