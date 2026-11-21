import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import KongFolio

final class PDFCommentAndImageExcerptTests: XCTestCase {
    private func document() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 512, height: 384)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 128, y: 96, width: 128, height: 96))
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    @MainActor func testCommentSurvivesExportAndReopeningForEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root)
        workspace.document = try document()
        let page = try XCTUnwrap(workspace.document.page(at: 0))
        let anchor = CGRect(x: 45, y: 175, width: 110, height: 16)
        XCTAssertFalse(workspace.saveInlineComment(" \n ", page: page, anchor: anchor))
        XCTAssertTrue(workspace.saveInlineComment("第一条评论", page: page, anchor: anchor, quote: "所选原文"))
        let bytes = try XCTUnwrap(workspace.document.dataRepresentation())
        workspace.document = try XCTUnwrap(PDFDocument(data: bytes))
        let reopened = try XCTUnwrap(workspace.document.page(at: 0))
        let card = try XCTUnwrap(reopened.annotations.first(where: PDFInlineComment.isCard))
        XCTAssertEqual(card.contents, "第一条评论")
        XCTAssertFalse(card.bounds.intersects(anchor))
        XCTAssertEqual(PDFInlineComment.anchor(of: card), anchor)
        let source = workspace.readingCitation(page: 0)
        let record = try XCTUnwrap(ReadingPDFCapture.record(card, page: reopened, index: 0, source: source))
        XCTAssertEqual(record.kind, .comment)
        XCTAssertEqual(record.quote, "所选原文")
        XCTAssertEqual(record.citations.first?.source.rects, [anchor])
        XCTAssertTrue(workspace.saveInlineComment("更新后的评论\n第二行", page: reopened, anchor: anchor, existing: card))
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertEqual(card.contents, "更新后的评论\n第二行")
        workspace.undo()
        XCTAssertEqual(reopened.annotations.first?.contents, "第一条评论")
    }

    func testImageExcerptUsesCropBoxOriginAndPageRotation() {
        let box = CGRect(x: 10, y: 20, width: 128, height: 64)
        let region = CGRect(x: 42, y: 28, width: 16, height: 16)
        let landscape = CGSize(width: 512, height: 256)
        let portrait = CGSize(width: 256, height: 512)
        XCTAssertEqual(PDFImageExcerpt.pixelBounds(for: region, cropBox: box, rotation: 0, imageSize: landscape),
                       CGRect(x: 128, y: 160, width: 64, height: 64))
        XCTAssertEqual(PDFImageExcerpt.pixelBounds(for: region, cropBox: box, rotation: 90, imageSize: portrait),
                       CGRect(x: 32, y: 128, width: 64, height: 64))
        XCTAssertEqual(PDFImageExcerpt.pixelBounds(for: region, cropBox: box, rotation: 180, imageSize: landscape),
                       CGRect(x: 320, y: 32, width: 64, height: 64))
        XCTAssertEqual(PDFImageExcerpt.pixelBounds(for: region, cropBox: box, rotation: 270, imageSize: portrait),
                       CGRect(x: 160, y: 320, width: 64, height: 64))
        XCTAssertNil(PDFImageExcerpt.pixelBounds(for: .zero, cropBox: box, rotation: 0, imageSize: landscape))
    }

    func testImageExcerptIsARegionPNGAtPDFResolution() throws {
        let document = try document()
        let page = try XCTUnwrap(document.page(at: 0))
        let region = CGRect(x: 128, y: 96, width: 128, height: 96)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let png = try PDFImageExcerpt.png(for: region, on: page)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let crop = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertGreaterThan(crop.width, 400)
            XCTAssertGreaterThan(crop.height, 400)
            let sample = try XCTUnwrap(crop.cropping(to: CGRect(x: crop.width / 2, y: crop.height / 2, width: 1, height: 1)))
            let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: sample).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(pixel.redComponent, 0.75, "Rotation \(rotation)")
            XCTAssertLessThan(pixel.greenComponent, 0.25, "Rotation \(rotation)")
        }
    }
}
