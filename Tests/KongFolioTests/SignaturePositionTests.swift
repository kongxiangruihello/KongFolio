import XCTest
import PDFKit
@testable import KongFolio

final class SignaturePositionTests: XCTestCase {
    final class StubView: PDFView, SignaturePlacing {
        var shownAt: (page: PDFPage, rect: CGRect)?
        var shown = false
        var target: (page: PDFPage, rect: CGRect)?
        func beginSignaturePlacement(_ image: CGImage, widthFraction: Double, page: PDFPage?, rect: CGRect?) {
            shown = true
            shownAt = page.flatMap { page in rect.map { (page, $0) } }
        }
        func resizeSignaturePlacement(widthFraction: Double) {}
        func signaturePlacement() -> (page: PDFPage, rect: CGRect)? { target }
        func endSignaturePlacement() { shown = false }
    }

    func document(pages: Int, rotation: Int = 0) -> PDFDocument {
        let doc = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
            page.rotation = rotation
            doc.insert(page, at: index)
        }
        return PDFDocument(data: doc.dataRepresentation()!)!
    }

    func square() -> CGImage {
        var data = [UInt8](repeating: 0, count: 10 * 10 * 4)
        for index in stride(from: 3, to: data.count, by: 4) { data[index] = 255 }
        return data.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    func testPageRules() {
        let last = SignaturePosition.presets[0]
        XCTAssertEqual(last.page, .last)
        XCTAssertEqual(last.pageIndex(current: 0, count: 5), 4)
        XCTAssertEqual(SignaturePosition(name: "x", page: .first, centerX: 0.5, centerY: 0.5, width: 0.2).pageIndex(current: 3, count: 5), 0)
        XCTAssertEqual(SignaturePosition(name: "x", page: .current, centerX: 0.5, centerY: 0.5, width: 0.2).pageIndex(current: 9, count: 5), 4)
        XCTAssertNil(last.pageIndex(current: 0, count: 0))
    }

    func testRectScalesWithThePageAndStaysInside() {
        let position = SignaturePosition(name: "x", page: .last, centerX: 0.75, centerY: 0.1, width: 0.25)
        let small = position.rect(aspect: 2, cropBox: CGRect(x: 0, y: 0, width: 200, height: 300), rotation: 0)
        XCTAssertEqual(small.width, 50, accuracy: 0.01)
        XCTAssertEqual(small.height, 25, accuracy: 0.01)
        XCTAssertEqual(small.midX, 150, accuracy: 0.01)
        XCTAssertEqual(small.midY, 30, accuracy: 0.01)
        let large = position.rect(aspect: 2, cropBox: CGRect(x: 0, y: 0, width: 400, height: 600), rotation: 0)
        XCTAssertEqual(large.width, 100, accuracy: 0.01)
        XCTAssertEqual(large.midX, 300, accuracy: 0.01)
        // A corner position never leaves the page.
        let corner = SignaturePosition(name: "c", page: .last, centerX: 1, centerY: 0, width: 0.5).rect(aspect: 1, cropBox: CGRect(x: 0, y: 0, width: 200, height: 300), rotation: 0)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 200, height: 300).contains(corner))
    }

    func testMakeAndRectRoundTripOnRotatedPages() {
        let crop = CGRect(x: 0, y: 0, width: 200, height: 300)
        for rotation in [0, 90, 180, 270] {
            let position = SignaturePosition(name: "r", page: .last, centerX: 0.7, centerY: 0.2, width: 0.3)
            let rect = position.rect(aspect: 2, cropBox: crop, rotation: rotation)
            let again = SignaturePosition.make(name: "r", page: .last, rect: rect, cropBox: crop, rotation: rotation)
            XCTAssertEqual(again.centerX, 0.7, accuracy: 0.001, "rotation \(rotation)")
            XCTAssertEqual(again.centerY, 0.2, accuracy: 0.001, "rotation \(rotation)")
            XCTAssertEqual(again.width, 0.3, accuracy: 0.001, "rotation \(rotation)")
        }
    }

    @MainActor func testPlacingAtAPresetShowsTheStampOnTheLastPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = document(pages: 4)
        workspace.addSignatureImage(square(), name: "签名")
        let view = StubView()
        workspace.pdfView = view
        let template = workspace.signatures[0]
        workspace.placeSignature(template, at: SignaturePosition.presets[0])
        XCTAssertNotNil(workspace.placingSignature)
        let shown = try view.shownAt.unwrap("没有显示签名")
        XCTAssertTrue(shown.page === workspace.document.page(at: 3))
        XCTAssertEqual(workspace.selection, 3)
        XCTAssertEqual(shown.rect.midX, 0.74 * 200, accuracy: 0.5)
        XCTAssertEqual(shown.rect.midY, 0.12 * 300, accuracy: 0.5)
        // Confirming writes it where the place said.
        view.target = shown
        workspace.confirmSignaturePlacement()
        XCTAssertNil(workspace.placingSignature)
        XCTAssertEqual(workspace.document.pageCount, 4)
    }

    @MainActor func testSavedPlacesSurviveARestartAndCanBeRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = document(pages: 3)
        workspace.addSignatureImage(square(), name: "签名")
        let view = StubView()
        workspace.pdfView = view
        workspace.beginPlacing(workspace.signatures[0])
        view.target = (workspace.document.page(at: 1)!, CGRect(x: 120, y: 30, width: 60, height: 30))
        workspace.rememberSignaturePosition(as: .last)
        XCTAssertEqual(workspace.signaturePositions.count, 1)
        let saved = workspace.signaturePositions[0]
        XCTAssertEqual(saved.page, .last)
        XCTAssertEqual(saved.centerX, 0.75, accuracy: 0.001)
        XCTAssertEqual(saved.width, 0.3, accuracy: 0.001)

        let reopened = Workspace(storage: directory)
        reopened.loadSignaturePositions()
        XCTAssertEqual(reopened.signaturePositions, [saved])
        XCTAssertEqual(reopened.allSignaturePositions.count, SignaturePosition.presets.count + 1)

        reopened.removeSignaturePosition(saved.id)
        XCTAssertTrue(reopened.signaturePositions.isEmpty)
        let again = Workspace(storage: directory)
        again.loadSignaturePositions()
        XCTAssertTrue(again.signaturePositions.isEmpty)
    }
}
