import XCTest
import PDFKit
@testable import KongFolio

final class OCRResumeTests: XCTestCase {
    func testPagesAreCutIntoChunksInOrder() {
        let parts = Workspace.chunks(Array(0..<25), size: 10)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], Array(0..<10))
        XCTAssertEqual(parts[2], [20, 21, 22, 23, 24])
        XCTAssertEqual(Workspace.chunks([3, 7], size: 10), [[3, 7]])
        XCTAssertEqual(Workspace.chunks([], size: 10).count, 0)
    }

    @MainActor func testProgressCountsFinishedChunks() {
        let workspace = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        XCTAssertEqual(workspace.chainProgress(0.5, pages: 10), 0.5, accuracy: 0.0001)
        var chain = OCRChain(total: 40, remaining: [])
        chain.done = 20
        workspace.ocrChain = chain
        XCTAssertEqual(workspace.chainProgress(0.5, pages: 10), 25.0 / 40.0, accuracy: 0.0001)
    }

    @MainActor func testResumeLeavesAlreadyRecognizedPagesAlone() throws {
        let workspace = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        let document = PDFDocument()
        for _ in 0..<3 { document.insert(PDFPage(), at: document.pageCount) }
        workspace.document = document
        for index in 0..<3 { workspace.updateMeta(index) { $0.ocrRegions = [RecognizedLine(text: "字", box: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))] } }
        workspace.ocr(resume: true)
        XCTAssertEqual(workspace.status, "所有页面都已识别")
        XCTAssertFalse(workspace.busy)
    }
}
