import XCTest
import PDFKit
import AppKit
import ImageIO
import CoreText
@testable import KongFolio

final class VersionThreeTests: XCTestCase {
    func fixture() throws -> PDFDocument {
        let doc = DocumentServicesTests().fixture()
        for i in 0..<3 {
            let page = try DocumentServices.searchablePage(doc.page(at: i)!, lines: [RecognizedLine(text: "KongFolio reading Search search", box: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1))])
            doc.removePage(at: i); doc.insert(page, at: i)
        }
        ReadingServices.applyOutline([OutlineEntry(page: 0, label: "First", depth: 0), OutlineEntry(page: 2, label: "Last", depth: 1)], to: doc)
        return doc
    }
    func testMouseCropGeometry() {
        let box = CropGeometry.selection(from: CGPoint(x: 90, y: 80), to: CGPoint(x: 10, y: -20), size: CGSize(width: 100, height: 100))
        XCTAssertEqual(box, CGRect(x: 0.1, y: 0, width: 0.8, height: 0.8))
        let moved = CropGeometry.move(box, dx: 3, dy: -1)
        XCTAssertEqual(Double(moved.minX), 0.2, accuracy: 0.00001); XCTAssertEqual(moved.minY, 0)
        let resized = CropGeometry.resize(box, anchorX: -1, anchorY: 1, dx: 2, dy: 2)
        XCTAssertEqual(Double(resized.width), 0.02, accuracy: 0.00001); XCTAssertEqual(resized.maxY, 1)
        let flipped = CropGeometry.imageCoordinates(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3))
        XCTAssertEqual(flipped, CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.3))
    }
    @MainActor func testComposedCropAndUndo() throws {
        let w = Workspace(); w.document = DocumentServicesTests().fixture(); w.mode = "Image"
        w.adjustments.crop = 0.1; w.updatePreview(); let before = w.preview!.size
        w.setCrop(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(w.adjustments.crop, 0)
        XCTAssertEqual(Double(w.preview!.size.width), Double(before.width) / 2, accuracy: 2)
        XCTAssertEqual(Double(w.preview!.size.height), Double(before.height) / 2, accuracy: 2)
        w.applyImage(); let cropped = w.page!.bounds(for: .cropBox)
        XCTAssertTrue(cropped.width < 300 && cropped.height < 400)
        w.undo(); XCTAssertEqual(w.page!.bounds(for: .cropBox).size, CGSize(width: 300, height: 400))
        w.redo(); XCTAssertEqual(w.page!.bounds(for: .cropBox), cropped)
    }
    @MainActor func testProjectMigrationAndReadingRemapping() throws {
        let w = Workspace(); w.document = try fixture(); w.bookmarks = [PageBookmark(page: 2, label: "Later")]; w.outlineEntries = ReadingServices.outline(w.document)
        w.readingLayout = "双页"; w.readingPoint = CGPoint(x: 20, y: 200); w.readingScale = 1.2
        let archive = try w.snapshot(), data = try JSONEncoder().encode(archive)
        let restored = Workspace(); try restored.restore(JSONDecoder().decode(ProjectArchive.self, from: data))
        XCTAssertEqual(restored.bookmarks, w.bookmarks); XCTAssertEqual(restored.readingLayout, "双页"); XCTAssertEqual(restored.readingPoint, w.readingPoint)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["version"] = 2; json.removeValue(forKey: "reading"); json.removeValue(forKey: "ocrOriginals"); json.removeValue(forKey: "ocrRegions")
        let old = try JSONDecoder().decode(ProjectArchive.self, from: JSONSerialization.data(withJSONObject: json)); try old.validate()
        XCTAssertTrue(old.reading == nil)
        w.selectPage(2); w.move(-1); XCTAssertEqual(w.bookmarks.first!.page, 1)
        w.duplicatePages(); XCTAssertEqual(w.bookmarks.map(\.page), [1, 2]); w.remove(); XCTAssertEqual(w.bookmarks.map(\.page), [1])
        w.undo(); XCTAssertEqual(w.bookmarks.map(\.page), [1, 2])
    }
    func testSearchOutlineAndNotes() throws {
        let doc = try fixture(), data = doc.dataRepresentation()!
        let hits = try ReadingServices.search(data, query: "SEARCH")
        XCTAssertEqual(hits.count, 6); XCTAssertEqual(hits.map(\.page), [0, 0, 1, 1, 2, 2])
        XCTAssertEqual(try ReadingServices.search(data, query: "search", limit: 2).count, 2)
        XCTAssertTrue(doc.page(at: 0)!.selection(for: hits[0].range)!.string!.lowercased() == "search")
        let selected = PDFDocument(data: try ExportServices.preservedPDF(doc, pages: [2, 0]))!
        XCTAssertEqual(ReadingServices.outline(selected).map(\.page), [1, 0])
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 200, width: 100, height: 30), forType: .highlight, withProperties: nil)
        note.contents = "My note"; note.setValue("Original\nquote", forAnnotationKey: ReadingServices.quoteKey); doc.page(at: 1)!.addAnnotation(note)
        let notes = ReadingServices.notes(PDFDocument(data: doc.dataRepresentation()!)!)
        XCTAssertEqual(notes.count, 1); XCTAssertEqual(notes[0].quote, "Original\nquote")
        let markdown = ReadingServices.markdown(title: "Source", notes: notes)
        XCTAssertTrue(markdown.contains("第 2 页") && markdown.contains("> Original\n> quote") && markdown.contains("My note"))
    }
    func testConfiguredExportDimensionsAndMetadata() throws {
        let folder = try VersionTwoTests().temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let doc = try fixture(); doc.page(at: 0)!.rotation = 90
        var options = ExportOptions(); options.format = "PNG"; options.dpi = 150
        let cg = try ExportServices.render(doc.page(at: 0)!, dpi: 150)
        XCTAssertEqual(cg.width, 834); XCTAssertEqual(cg.height, 625)
        let encoded = try ExportServices.encode(cg, options: options)
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(encoded as CFData, nil)!, 0, nil)! as NSDictionary
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue, 834)
        XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as! NSNumber).doubleValue, 150, accuracy: 0.1)
        let source = doc.dataRepresentation()!
        let estimate = try ExportServices.estimate(data: source, pages: [0], options: options)
        let target = folder.appendingPathComponent("test.png")
        _ = try ExportServices.run(JobSpec(operation: .configured, source: source, pages: [0], destination: target, revision: UUID(), exportOptions: options)) { _ in }
        XCTAssertEqual(try Data(contentsOf: target).count, estimate.bytes)
        options.format = "PDF"; options.rasterPDF = true; options.dpi = 72
        let pdfURL = folder.appendingPathComponent("raster.pdf")
        _ = try ExportServices.run(JobSpec(operation: .configured, source: source, pages: [0], destination: pdfURL, revision: UUID(), exportOptions: options)) { _ in }
        let raster = PDFDocument(url: pdfURL)!
        XCTAssertEqual(raster.page(at: 0)!.bounds(for: .mediaBox).size, CGSize(width: 400, height: 300)); XCTAssertTrue((raster.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let kept = PDFDocument(data: try ExportServices.preservedPDF(doc, pages: [0, 1, 2]))!
        XCTAssertTrue(kept.string!.contains("KongFolio")); XCTAssertEqual(ReadingServices.outline(kept).count, 2)
        XCTAssertThrowsError(try ExportServices.pixels(doc.page(at: 0)!, dpi: 0))
    }
    func testConfiguredBatchCancellation() async throws {
        let folder = try VersionTwoTests().temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        var options = ExportOptions(); options.format = "PNG"; options.dpi = 72
        let spec = JobSpec(operation: .configured, source: try fixture().dataRepresentation()!, pages: [0, 1, 2], destination: folder, revision: UUID(), exportOptions: options)
        let gate = TestGate(), box = TestTaskBox()
        let task = Task.detached { () throws -> JobResult in await gate.wait(); return try ExportServices.run(spec) { _ in box.cancel() } }
        box.task = task; await gate.open()
        do { _ = try await task.value; XCTAssertTrue(false) } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 0)
    }
    func testOCRReviewAndReRecognition() throws {
        let doc = try fixture(), raster = PDFDocument()
        raster.insert(PDFPage(image: NSImage(cgImage: try ExportServices.render(doc.page(at: 0)!, dpi: 300), size: CGSize(width: 300, height: 400)))!, at: 0)
        // Add visible text in a raster image: the fixture's selectable text layer is invisible.
        let ctx = CGContext(data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        ctx.textPosition = CGPoint(x: 50, y: 140)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "KongFolio Review", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 64, nil)])), ctx)
        raster.removePage(at: 0); raster.insert(PDFPage(image: NSImage(cgImage: ctx.makeImage()!, size: CGSize(width: 600, height: 150)))!, at: 0)
        let source = raster.dataRepresentation()!
        let inspection = try BackgroundJobs.run(JobSpec(operation: .inspectOCR, source: source, pages: [0], revision: UUID())) { _ in }
        XCTAssertTrue(inspection.pdf == nil); XCTAssertTrue(inspection.regions[0]!.map(\.text).joined().contains("KongFolio"))
        let first = try BackgroundJobs.run(JobSpec(operation: .ocr, source: source, pages: [0], revision: UUID())) { _ in }
        let second = try BackgroundJobs.run(JobSpec(operation: .ocr, source: first.pdf!, pages: [0], revision: UUID(), forceOCR: true, ocrSources: first.originals)) { _ in }
        XCTAssertEqual(PDFDocument(data: second.pdf!)!.findString("KongFolio", withOptions: []).count, 1)
        XCTAssertTrue(second.regions[0]!.first!.confidence > 0)
    }
    func testImportPreservesOutline() throws {
        let folder = try VersionTwoTests().temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.pdf"); try fixture().dataRepresentation()!.write(to: url)
        if case .documents(let documents) = try ImportServices.read([url]) { XCTAssertEqual(documents.count, 1); XCTAssertEqual(ReadingServices.outline(PDFDocument(data: documents[0])!).count, 2) }
        else { XCTAssertTrue(false) }
    }
}
