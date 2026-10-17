import XCTest
import PDFKit
@testable import KongFolio

final class SignatureTests: XCTestCase {
    /// A photographed signature: paper that gets darker from left to right, with a dark stroke on it.
    func photo(width: Int = 400, height: Int = 200, gradient: Bool = true, ink: Bool = true) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let paper = gradient ? 0.97 - 0.25 * Double(x) / Double(width) : 1
            let base = (y * width + x) * 4
            var value = paper
            if ink && x >= 120 && x < 280 && y >= 80 && y < 90 { value = 0.12 }
            let byte = UInt8(value * 255)
            data[base] = byte; data[base + 1] = byte; data[base + 2] = byte; data[base + 3] = 255
        } }
        let context = data.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        return context.makeImage()!
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        // y counts from the bottom edge.
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let row = image.height - 1 - y
        let base = (row * image.width + x) * 4
        return (Int(bytes[base]), Int(bytes[base + 1]), Int(bytes[base + 2]), Int(bytes[base + 3]))
    }

    func testPaperBecomesTransparentAndInkStays() throws {
        let result = try SignatureImage.process(photo(), options: SignatureOptions()).unwrap("没有结果")
        // Trimmed to the stroke (160x10 plus margin), not the whole photo.
        XCTAssertTrue(result.width < 200)
        XCTAssertTrue(result.height < 40)
        XCTAssertTrue(result.width >= 160)
        let middle = pixel(result, result.width / 2, result.height / 2)
        XCTAssertTrue(middle.a > 200)
        XCTAssertTrue(middle.r < 40)
        let corner = pixel(result, 1, 1)
        XCTAssertEqual(corner.a, 0)
    }

    func testUnevenLightingNeedsTheCorrection() throws {
        var options = SignatureOptions(); options.trim = false; options.evenOutLight = true
        let flat = try SignatureImage.process(photo(), options: options).unwrap("没有结果")
        // The darkest paper (right edge, 0.72) is still removed.
        XCTAssertEqual(pixel(flat, flat.width - 3, 5).a, 0)
        XCTAssertEqual(pixel(flat, 3, 5).a, 0)
    }

    func testTintReplacesInkColour() throws {
        var options = SignatureOptions(); options.tint = .blue
        let result = try SignatureImage.process(photo(), options: options).unwrap("没有结果")
        let ink = pixel(result, result.width / 2, result.height / 2)
        XCTAssertTrue(ink.b > ink.r + 60)
    }

    func testImageWithoutInkIsRejected() {
        XCTAssertNil(SignatureImage.process(photo(ink: false), options: SignatureOptions()))
        XCTAssertNil(SignatureImage.process(photo(gradient: false, ink: false), options: SignatureOptions()))
    }

    func testBackgroundCanBeKept() throws {
        var options = SignatureOptions(); options.removeBackground = false
        let result = try SignatureImage.process(photo(gradient: false), options: options).unwrap("没有结果")
        XCTAssertEqual(result.width, 400)
        XCTAssertEqual(pixel(result, 5, 5).a, 255)
    }

    func testPNGRoundTrip() throws {
        let processed = try SignatureImage.process(photo(), options: SignatureOptions()).unwrap("没有结果")
        let data = try SignatureImage.pngData(processed).unwrap("没有 PNG")
        let source = try CGImageSourceCreateWithData(data as CFData, nil).unwrap("无法读取")
        let decoded = try CGImageSourceCreateImageAtIndex(source, 0, nil).unwrap("无法解码")
        XCTAssertEqual(decoded.width, processed.width)
        XCTAssertTrue(pixel(decoded, 1, 1).a == 0)
    }

    func testOldLibraryFilesStillDecode() throws {
        let id = UUID()
        let old = "[{\"id\":\"\(id.uuidString)\",\"name\":\"签名 1\",\"pdf\":\"AQID\"}]"
        let list = try JSONDecoder().decode([SignatureTemplate].self, from: Data(old.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].image)
        let withImage = SignatureTemplate(name: "图", pdf: Data(), image: Data([1, 2, 3]))
        let back = try JSONDecoder().decode(SignatureTemplate.self, from: JSONEncoder().encode(withImage))
        XCTAssertEqual(back.image, Data([1, 2, 3]))
    }

    func testUprightRectFollowsPageRotation() {
        let size = CGSize(width: 200, height: 300)
        let rect = CGRect(x: 50, y: 20, width: 40, height: 10)
        XCTAssertEqual(SignatureStamp.uprightRect(rect, pageSize: size, rotation: 0), rect)
        XCTAssertEqual(SignatureStamp.uprightRect(rect, pageSize: size, rotation: 90), CGRect(x: 20, y: 110, width: 10, height: 40))
        XCTAssertEqual(SignatureStamp.uprightRect(rect, pageSize: size, rotation: 180), CGRect(x: 110, y: 270, width: 40, height: 10))
        XCTAssertEqual(SignatureStamp.uprightRect(rect, pageSize: size, rotation: 270), CGRect(x: 270, y: 50, width: 10, height: 40))
        XCTAssertEqual(SignatureStamp.uprightRect(rect, pageSize: size, rotation: -90), SignatureStamp.uprightRect(rect, pageSize: size, rotation: 270))
    }

    func testFitKeepsAspectAndStaysInsideThePage() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let rect = SignatureStamp.fit(aspect: 4, width: 120, center: CGPoint(x: 290, y: 5), in: bounds)
        XCTAssertEqual(Double(rect.width / rect.height), 4, accuracy: 0.01)
        XCTAssertTrue(bounds.contains(rect))
    }

    // MARK: Writing into the PDF

    func blankDocument(pages: Int = 2, rotation: Int = 0) -> PDFDocument {
        let doc = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
            page.rotation = rotation
            doc.insert(page, at: index)
        }
        // Serialize once so pages have page references, like a document that was loaded from a file.
        return PDFDocument(data: doc.dataRepresentation()!)!
    }

    func blackSquare() -> CGImage {
        var data = [UInt8](repeating: 0, count: 10 * 10 * 4)
        for index in stride(from: 3, to: data.count, by: 4) { data[index] = 255 }
        return data.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    func rendered(_ page: PDFPage, width: Int, height: Int) -> CGImage {
        let image = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testBakedSignatureLandsAtThePlacedPosition() throws {
        let doc = blankDocument()
        let page = try doc.page(at: 0).unwrap("没有页面")
        let baked = try SignatureStamp.bake(blackSquare(), onto: page, userRect: CGRect(x: 50, y: 50, width: 40, height: 40)).unwrap("没有结果")
        let image = rendered(baked, width: 200, height: 300)
        XCTAssertTrue(pixel(image, 70, 70).r < 60)
        XCTAssertTrue(pixel(image, 150, 250).r > 200)
        XCTAssertTrue(pixel(image, 70, 150).r > 200)
    }

    func testBakedSignatureOnRotatedPage() throws {
        let doc = blankDocument(rotation: 90)
        let page = try doc.page(at: 0).unwrap("没有页面")
        XCTAssertEqual(page.rotation, 90)
        let baked = try SignatureStamp.bake(blackSquare(), onto: page, userRect: CGRect(x: 50, y: 50, width: 40, height: 40)).unwrap("没有结果")
        let upright = SignatureStamp.uprightRect(CGRect(x: 50, y: 50, width: 40, height: 40), pageSize: CGSize(width: 200, height: 300), rotation: 90)
        let image = rendered(baked, width: 300, height: 200)
        XCTAssertTrue(pixel(image, Int(upright.midX), Int(upright.midY)).r < 60)
        XCTAssertTrue(pixel(image, 250, 150).r > 200)
    }

    func testAnnotationsSurviveOnAnUnrotatedPage() throws {
        let doc = blankDocument()
        let page = try doc.page(at: 0).unwrap("没有页面")
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 120, height: 30), forType: .freeText, withProperties: nil)
        note.contents = "保留我"
        page.addAnnotation(note)
        let committed = try PDFDocument(data: doc.dataRepresentation().unwrap("无法序列化")).unwrap("无法读取")
        let baked = try SignatureStamp.bake(blackSquare(), onto: try committed.page(at: 0).unwrap("没有页面"), userRect: CGRect(x: 50, y: 150, width: 40, height: 40)).unwrap("没有结果")
        XCTAssertTrue(baked.annotations.contains { $0.contents == "保留我" })
    }

    @MainActor final class StubView: PDFView, SignaturePlacing {
        var shown: (CGImage, Double)?
        var target: (page: PDFPage, rect: CGRect)?
        func beginSignaturePlacement(_ image: CGImage, widthFraction: Double) { shown = (image, widthFraction) }
        func resizeSignaturePlacement(widthFraction: Double) { shown?.1 = widthFraction }
        func signaturePlacement() -> (page: PDFPage, rect: CGRect)? { target }
        func endSignaturePlacement() { shown = nil }
    }

    @MainActor func testPlacingFromTheLibraryChangesOnlyThatPageAndCanBeUndone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = blankDocument(pages: 3)
        workspace.addSignatureImage(blackSquare(), name: "我的签名")
        let template = try workspace.signatures.first.unwrap("签名库为空")
        XCTAssertEqual(template.name, "我的签名")
        // The library survives a restart.
        let stored = try JSONDecoder().decode([SignatureTemplate].self, from: Data(contentsOf: directory.appendingPathComponent("Signatures.json")))
        XCTAssertEqual(stored.count, 1)
        XCTAssertNotNil(stored[0].image)

        let view = StubView()
        workspace.pdfView = view
        workspace.beginPlacing(template)
        XCTAssertNotNil(view.shown)
        XCTAssertNotNil(workspace.placingSignature)
        view.target = (try workspace.document.page(at: 1).unwrap("没有页面"), CGRect(x: 60, y: 100, width: 50, height: 50))
        workspace.confirmSignaturePlacement()
        XCTAssertNil(workspace.placingSignature)
        XCTAssertNil(view.shown)
        XCTAssertEqual(workspace.document.pageCount, 3)
        XCTAssertTrue(pixel(rendered(try workspace.document.page(at: 1).unwrap("没有页面"), width: 200, height: 300), 85, 125).r < 60)
        XCTAssertTrue(pixel(rendered(try workspace.document.page(at: 0).unwrap("没有页面"), width: 200, height: 300), 85, 125).r > 200)
        workspace.undo()
        XCTAssertTrue(pixel(rendered(try workspace.document.page(at: 1).unwrap("没有页面"), width: 200, height: 300), 85, 125).r > 200)
    }
}
