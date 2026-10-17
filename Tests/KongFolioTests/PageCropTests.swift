import XCTest
import PDFKit
@testable import KongFolio

final class PageCropTests: XCTestCase {
    /// `pages` pages of 200 x 300 with a black block at x 40...160 and y (from the top) 60...240.
    func book(pages: Int, rotation: Int = 0) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(box)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 40, y: 60, width: 120, height: 180))
            context.endPDFPage()
        }
        context.closePDF()
        let document = try PDFDocument(data: data as Data).unwrap("无法读取")
        for index in 0..<pages { document.page(at: index)?.rotation = rotation }
        return PDFDocument(data: document.dataRepresentation()!)!
    }

    func testCropBoxFollowsTheMarginsOnUnrotatedPages() {
        let media = CGRect(x: 0, y: 0, width: 200, height: 300)
        let box = PageCrop.cropBox(mediaBox: media, rotation: 0, margins: CropMargins(left: 0.1, right: 0.2, top: 0.05, bottom: 0.1))
        XCTAssertEqual(box.minX, 20, accuracy: 0.01)
        XCTAssertEqual(box.minY, 30, accuracy: 0.01)
        XCTAssertEqual(box.width, 140, accuracy: 0.01)
        XCTAssertEqual(box.height, 255, accuracy: 0.01)
    }

    func testMarginsRoundTripOnEveryRotationAndOffsetPages() {
        let media = CGRect(x: 10, y: 20, width: 200, height: 300)
        let wanted = CropMargins(left: 0.1, right: 0.2, top: 0.05, bottom: 0.15)
        for rotation in [0, 90, 180, 270] {
            let box = PageCrop.cropBox(mediaBox: media, rotation: rotation, margins: wanted)
            XCTAssertTrue(media.contains(box))
            let back = PageCrop.margins(of: box, mediaBox: media, rotation: rotation)
            XCTAssertEqual(back.left, wanted.left, accuracy: 0.001)
            XCTAssertEqual(back.right, wanted.right, accuracy: 0.001)
            XCTAssertEqual(back.top, wanted.top, accuracy: 0.001)
            XCTAssertEqual(back.bottom, wanted.bottom, accuracy: 0.001)
        }
    }

    func testMarginsAreKeptSensible() {
        let wild = CropMargins(left: 0.9, right: 0.9, top: -1, bottom: .nan).clamped
        XCTAssertTrue(wild.left + wild.right <= 0.9 + 1e-9)
        XCTAssertEqual(wild.top, 0)
        XCTAssertEqual(wild.bottom, 0)
        XCTAssertTrue(CropMargins.zero.isZero)
    }

    func testContentBoundsFindThePrintedAreaAndIgnoreEdgesAndSpecks() throws {
        let width = 200, height = 300
        var pixels = [UInt8](repeating: 240, count: width * height)
        for y in 0..<height { for x in 0..<width where x < 6 || x >= width - 6 { pixels[y * width + x] = 20 } }      // dark scanner edges
        for y in 70..<230 { for x in 50..<150 { pixels[y * width + x] = 30 } }                                          // the text block
        pixels[5 * width + 100] = 0                                                                                       // a speck near the top
        let found = try (ContentBounds.margins(pixels: pixels, width: width, height: height)).unwrap("没有找到内容")
        XCTAssertEqual(found.left, 0.25, accuracy: 0.02)
        XCTAssertEqual(found.right, 0.25, accuracy: 0.02)
        XCTAssertEqual(found.top, 70.0 / 300, accuracy: 0.02)
        XCTAssertEqual(found.bottom, 70.0 / 300, accuracy: 0.02)
        XCTAssertNil(ContentBounds.margins(pixels: [UInt8](repeating: 255, count: width * height), width: width, height: height))
    }

    func testCommonMarginsIgnoreAnOddPageOut() {
        var samples = Array(repeating: CropMargins(left: 0.2, right: 0.2, top: 0.1, bottom: 0.1), count: 19)
        samples.append(CropMargins(left: 0.02, right: 0.02, top: 0.01, bottom: 0.01))      // a page whose text runs to the edge
        let common = ContentBounds.common(of: samples)
        XCTAssertEqual(common.left, 0.188, accuracy: 0.001)     // 0.2 less the padding; the odd page does not drag it to 0
        XCTAssertTrue(ContentBounds.common(of: []).isZero)
    }

    func testRenderedPagesGiveTheSameMargins() throws {
        for rotation in [0, 90] {
            let document = try book(pages: 1, rotation: rotation)
            let page = try document.page(at: 0).unwrap("无页面")
            let bitmap = try (ContentBounds.render(page)).unwrap("没有找到内容")
            let found = try (ContentBounds.margins(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)).unwrap("没有找到内容")
            if rotation == 0 {
                XCTAssertEqual(found.left, 0.2, accuracy: 0.03)
                XCTAssertEqual(found.top, 0.2, accuracy: 0.03)
            } else {
                // Turned a quarter, the 200-wide side is now the height: the 20 % side margins became top and bottom margins.
                XCTAssertEqual(found.top, 0.2, accuracy: 0.03)
                XCTAssertEqual(found.left, 0.2, accuracy: 0.03)
            }
        }
    }

    @MainActor func testApplyingTheCropSurvivesSavingAndCanBeUndoneOrReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = try book(pages: 4)
        workspace.cropOdd = CropMargins(left: 0.1, right: 0.2, top: 0.1, bottom: 0.1)
        workspace.cropEven = CropMargins(left: 0.2, right: 0.1, top: 0.1, bottom: 0.1)
        workspace.cropSeparate = true
        workspace.cropScope = .all
        workspace.applyCrop()
        let first = try workspace.document.page(at: 0).unwrap("无页面").bounds(for: .cropBox)
        let second = try workspace.document.page(at: 1).unwrap("无页面").bounds(for: .cropBox)
        XCTAssertEqual(first.minX, 20, accuracy: 0.01)
        XCTAssertEqual(second.minX, 40, accuracy: 0.01)
        XCTAssertEqual(first.width, 140, accuracy: 0.01)

        // The cut is stored in the saved PDF.
        let reloaded = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取保存结果")
        let saved = try reloaded.page(at: 2).unwrap("无页面").bounds(for: .cropBox)
        XCTAssertEqual(saved.minX, 20, accuracy: 0.5)
        XCTAssertEqual(saved.width, 140, accuracy: 0.5)

        workspace.undo()
        XCTAssertEqual(try workspace.document.page(at: 0).unwrap("无页面").bounds(for: .cropBox).width, 200, accuracy: 0.5)

        workspace.applyCrop()
        workspace.cropScope = .selected
        workspace.selectedPages = [1]
        workspace.resetCrop()
        XCTAssertEqual(try workspace.document.page(at: 1).unwrap("无页面").bounds(for: .cropBox).width, 200, accuracy: 0.5)
        XCTAssertEqual(try workspace.document.page(at: 0).unwrap("无页面").bounds(for: .cropBox).width, 140, accuracy: 0.5)
    }

    @MainActor func testDetectingProposesSeparateMarginsForOddAndEvenPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = try book(pages: 6)
        workspace.cropScope = .all
        workspace.detectCrop()
        for _ in 0..<100 where workspace.cropDetecting { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(workspace.cropDetecting)
        XCTAssertTrue(workspace.cropSeparate)
        // The block is 20 % in from the sides and from the top and bottom; a little padding stays.
        XCTAssertEqual(workspace.cropOdd.left, 0.2 - 0.012, accuracy: 0.04)
        XCTAssertEqual(workspace.cropEven.top, 0.2 - 0.012, accuracy: 0.04)
        XCTAssertTrue(workspace.cropMessage.contains("6 页"))
    }
}
