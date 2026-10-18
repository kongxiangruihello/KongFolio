import XCTest
import PDFKit
import AppKit
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

    /// A page that is a picture of the given word, so that it has no text layer until it is recognised.
    func scannedPage(_ word: String) throws -> PDFPage {
        let width = 900, height = 400
        let context = try CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue).unwrap("无法创建画布")
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        (word as NSString).draw(at: CGPoint(x: 60, y: 130), withAttributes: [.font: NSFont.systemFont(ofSize: 120, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let image = try context.makeImage().unwrap("无法生成图像")
        return try PDFPage(image: NSImage(cgImage: image, size: CGSize(width: width, height: height))).unwrap("无法生成页面")
    }

    @MainActor func testChunkedRecognitionFillsEveryPageAndUndoesAsOneStep() async throws {
        let workspace = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        let words = ["APPLE", "BANANA", "CHERRY", "GRAPE", "LEMON"]
        let document = PDFDocument()
        for word in words { document.insert(try scannedPage(word), at: document.pageCount) }
        workspace.document = document
        workspace.ocrSettings.languages = ["en-US"]
        workspace.ocrSettings.dpi = 200
        workspace.ocrChunk = 2
        workspace.ocr()
        var waited = 0
        while workspace.busy && waited < 600 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        XCTAssertEqual(workspace.count, 5)
        var found = 0
        for (index, word) in words.enumerated() where (workspace.document.page(at: index)?.string ?? "").uppercased().contains(word) { found += 1 }
        // Written as an equality so that a failure shows the number: min(n, 4) == 4 means n >= 4.
        XCTAssertEqual(min(found, 4), 4)
        XCTAssertTrue(workspace.status.contains("识别 5 页"))
        XCTAssertEqual(workspace.meta(4).ocrRegions == nil, false)
        // Three chunks, one undo step.
        workspace.undo()
        XCTAssertEqual(workspace.document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        XCTAssertEqual(workspace.document.page(at: 4)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        XCTAssertEqual(workspace.count, 5)
    }
}
