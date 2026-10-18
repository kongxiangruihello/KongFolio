import XCTest
import PDFKit
import CoreText
import AppKit
import UniformTypeIdentifiers
@testable import KongFolio

final class DocumentServicesTests: XCTestCase {
    func fixture() -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            context.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0.3, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 20, y: 30, width: 100, height: 80))
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }
    func testSubsetOrderAndIsolation() throws {
        let doc = fixture(); doc.page(at: 2)!.rotation = 90
        let subset = DocumentServices.subset(doc, indexes: [2, 0])
        XCTAssertEqual(subset.pageCount, 2); XCTAssertEqual(subset.page(at: 0)!.rotation, 90)
        subset.page(at: 0)!.rotation = 180
        XCTAssertEqual(doc.page(at: 2)!.rotation, 90)
        let roundtrip = PDFDocument(data: subset.dataRepresentation()!)!
        XCTAssertEqual(roundtrip.pageCount, 2)
    }
    func testSearchableLayerSurvivesSaveAndRotation() throws {
        let source = fixture()
        let page = source.page(at: 0)!; page.rotation = 90
        let lines = [RecognizedLine(text: "KongFolio searchable document", box: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.07))]
        let searchable = try withExtendedLifetime(source) { try DocumentServices.searchablePage(page, lines: lines) }
        let doc = PDFDocument(); doc.insert(searchable, at: 0)
        let reloaded = PDFDocument(data: doc.dataRepresentation()!)!
        XCTAssertTrue(reloaded.string?.contains("KongFolio") == true)
        XCTAssertEqual(reloaded.findString("searchable", withOptions: []).count, 1)
        XCTAssertEqual(reloaded.page(at: 0)!.bounds(for: .mediaBox).size, CGSize(width: 400, height: 300))
    }
    func testVisionRecognizesRasterText() throws {
        let ctx = CGContext(data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        let text = NSAttributedString(string: "KongFolio Document 2026", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 64, nil)])
        ctx.textPosition = CGPoint(x: 50, y: 140); CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        let result = try DocumentServices.recognize(ctx.makeImage()!)
        XCTAssertTrue(result.map(\.text).joined(separator: " ").contains("KongFolio"))
    }
    func testAnnotationsSurvivePDFExport() throws {
        let doc = fixture(); let page = doc.page(at: 0)!
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 28, height: 28), forType: .text, withProperties: nil)
        note.contents = "Review note"; page.addAnnotation(note)
        let ink = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.move(to: CGPoint(x: 20, y: 20)); path.line(to: CGPoint(x: 90, y: 90)); ink.add(path); page.addAnnotation(ink)
        let roundtrip = PDFDocument(data: doc.dataRepresentation()!)!
        // Newer macOS versions add a Popup annotation for text notes on save; it is not user content.
        XCTAssertEqual(Workspace.visibleAnnotations(on: roundtrip.page(at: 0)!).count, 2)
        XCTAssertTrue(roundtrip.page(at: 0)!.annotations.contains { $0.contents == "Review note" })
    }
    func testInvalidImportFails() {
        XCTAssertThrowsError(try DocumentServices.load(URL(fileURLWithPath: "/nonexistent/test.pdf")))
    }
    @MainActor func testPageEditsUndoRedo() throws {
        let model = Workspace(); model.document = fixture()
        model.selectPage(2); model.rotate(); XCTAssertEqual(model.page!.rotation, 90)
        model.move(-1); XCTAssertEqual(model.selection, 1); XCTAssertEqual(model.page!.rotation, 90)
        model.remove(); XCTAssertEqual(model.count, 2)
        model.undo(); XCTAssertEqual(model.count, 3); XCTAssertEqual(model.page!.rotation, 90)
        model.redo(); XCTAssertEqual(model.count, 2)
    }
}
