import XCTest
import PDFKit
import CoreText
@testable import KongFolio

final class CompressTests: XCTestCase {
    /// Page 1 is a "scan" (a large lossless picture with some text on it), page 2 holds text only.
    func makeScan() throws -> (document: PDFDocument, data: Data) {
        let width = 1400, height = 1800
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 1664525 &+ 1013904223
            let noise = Int((seed >> 24) % 13) - 6
            let base = 150 + (x * 60 / width) + (y * 40 / height)
            let value = UInt8(max(0, min(255, base + noise)))
            let index = (y * width + x) * 4
            pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = UInt8(max(0, min(255, Int(value) - 12))); pixels[index + 3] = 255
        } }
        let picture = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        func draw(_ text: String, at y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(line, context)
        }
        context.beginPDFPage(nil)
        context.draw(picture, in: box)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw("SCANNED PAGE ONE", at: 400)
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw("PLAIN TEXT PAGE", at: 400)
        context.endPDFPage()
        context.closePDF()
        let bytes = data as Data
        return (try PDFDocument(data: bytes).unwrap("无法读取测试文档"), bytes)
    }

    func testImageBytesFindsOnlyPicturePages() throws {
        let (document, _) = try makeScan()
        XCTAssertTrue(PDFCompressor.imageBytes(try document.page(at: 0).unwrap("无页面")) > PDFCompressor.minimumImageBytes)
        XCTAssertEqual(PDFCompressor.imageBytes(try document.page(at: 1).unwrap("无页面")), 0)
    }

    func testStandardShrinksTheScanAndKeepsTextPagesAndSearchableText() throws {
        let (document, original) = try makeScan()
        let (data, report) = try PDFCompressor.compress(document, level: .standard, original: original.count) { _ in }
        print("压缩：\(original.count) → \(data.count) 字节")
        XCTAssertTrue(data.count < original.count / 2)
        XCTAssertTrue(report.smaller)
        XCTAssertEqual(report.rebuilt, 1)
        XCTAssertEqual(report.kept, 1)
        let result = try PDFDocument(data: data).unwrap("压缩结果无法读取")
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.page(at: 0)?.string?.contains("SCANNED") == true)
        XCTAssertTrue(result.page(at: 1)?.string?.contains("PLAIN") == true)
        let size = result.page(at: 0)!.bounds(for: .mediaBox).size
        XCTAssertEqual(Double(size.width), 595, accuracy: 0.5)
    }

    func testStrongIsNotLargerThanStandard() throws {
        let standard = try PDFCompressor.compress(try makeScan().document, level: .standard, original: 0) { _ in }
        let strong = try PDFCompressor.compress(try makeScan().document, level: .strong, original: 0) { _ in }
        XCTAssertTrue(strong.data.count <= standard.data.count)
    }

    func testLightKeepsEveryPageAsItWas() throws {
        let (document, original) = try makeScan()
        let (data, report) = try PDFCompressor.compress(document, level: .light, original: original.count) { _ in }
        XCTAssertEqual(try PDFDocument(data: data).unwrap("无法读取").pageCount, 2)
        XCTAssertEqual(report.rebuilt, 0)
    }

    func testReportWordsAFileThatDidNotShrink() {
        let same = CompressReport(before: 1000, after: 1200, rebuilt: 2, kept: 1)
        XCTAssertFalse(same.smaller)
        XCTAssertTrue(same.summary.contains("没有变小"))
        let nothing = CompressReport(before: 1000, after: 1000, rebuilt: 0, kept: 3)
        XCTAssertTrue(nothing.summary.contains("没有找到可以压缩的大图片页面"))
        let light = CompressReport(before: 1000, after: 1000, rebuilt: 0, kept: 3, viaPDFKit: true)
        XCTAssertTrue(light.summary.contains("没有变小"))
        let better = CompressReport(before: 1_000_000, after: 400_000, rebuilt: 2, kept: 1)
        XCTAssertTrue(better.summary.contains("减少 60%"))
        XCTAssertTrue(better.summary.contains("重绘 2 页"))
    }

    func testTextOnlyDocumentIsLeftAlone() throws {
        let document = try TextImport.render("学而时习之，不亦说乎？", markdown: false)
        let data = try document.dataRepresentation().unwrap("无法序列化")
        let (_, report) = try PDFCompressor.compress(document, level: .standard, original: data.count) { _ in }
        XCTAssertEqual(report.rebuilt, 0)
        XCTAssertFalse(report.smaller)
        XCTAssertTrue(report.summary.contains("没有找到可以压缩的大图片页面"))
    }

    func testPagesWithMarksCanBeLeftAlone() throws {
        func marked() throws -> PDFDocument {
            let (document, _) = try makeScan()
            let mark = PDFAnnotation(bounds: CGRect(x: 60, y: 395, width: 200, height: 24), forType: .highlight, withProperties: nil)
            mark.color = NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 0.4)
            try document.page(at: 0).unwrap("无页面").addAnnotation(mark)
            return document
        }
        let scan = PDFCompressor.scan(try marked())
        XCTAssertEqual(scan.pictureHeavy, 1)
        XCTAssertEqual(scan.marked, 1)

        let kept = try PDFCompressor.compress(try marked(), level: .standard, original: 1, keepMarked: true) { _ in }
        XCTAssertEqual(kept.report.rebuilt, 0)
        XCTAssertFalse(kept.report.smaller)

        let redrawn = try PDFCompressor.compress(try marked(), level: .standard, original: 10_000_000, keepMarked: false) { _ in }
        XCTAssertEqual(redrawn.report.rebuilt, 1)
    }

    /// Pictures wrapped in a group (a transparency layer is written as a form XObject) are still found.
    func testPicturesInsideAGroupAreFound() throws {
        let width = 1200, height = 1500
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 99
        for index in 0..<(width * height) {
            seed = seed &* 1664525 &+ 1013904223
            let value = UInt8(120 + Int((seed >> 24) % 20))
            pixels[index * 4] = value; pixels[index * 4 + 1] = value; pixels[index * 4 + 2] = value; pixels[index * 4 + 3] = 255
        }
        let picture = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setAlpha(0.9)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.draw(picture, in: box)
        context.endTransparencyLayer()
        context.endPDFPage()
        context.closePDF()
        let document = try PDFDocument(data: data as Data).unwrap("无法读取")
        XCTAssertTrue(PDFCompressor.imageBytes(try document.page(at: 0).unwrap("无页面")) > PDFCompressor.minimumImageBytes)
    }
}
