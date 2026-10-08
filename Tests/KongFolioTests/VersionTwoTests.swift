import XCTest
import PDFKit
import AppKit
@testable import KongFolio

final class VersionTwoTests: XCTestCase {
    func fixture() -> PDFDocument { DocumentServicesTests().fixture() }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolioTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testPageRanges() throws {
        XCTAssertEqual(try PageRange.parse("1–3, 5, 3", count: 5), [0, 1, 2, 4])
        for invalid in ["", "0", "6", "3-1", "1,", "1--3", "-1", "2-x"] { XCTAssertThrowsError(try PageRange.parse(invalid, count: 5)) }
    }
    @MainActor func testMultiSelectionAndRecipeRemapping() throws {
        let w = Workspace(); w.document = fixture()
        for i in 0..<3 { w.document.page(at: i)!.rotation = i * 90 }
        let original = DocumentServices.subset(w.document, indexes: [1]).dataRepresentation()!
        w.recipes[1] = ImageRecipe(originalPDF: original, adjustments: ImageAdjustments())
        w.selectedPages = [0, 1]; w.move(1)
        XCTAssertEqual((0..<3).map { w.document.page(at: $0)!.rotation }, [180, 0, 90]); XCTAssertTrue(w.recipes[2] != nil)
        w.duplicatePages(); XCTAssertEqual(w.count, 5); XCTAssertEqual(w.effectivePages, [3, 4]); XCTAssertTrue(w.recipes[4] != nil)
        w.remove(); XCTAssertEqual(w.count, 3); w.undo(); XCTAssertEqual(w.count, 5); XCTAssertTrue(w.recipes[4] != nil)
        w.movePages(before: 0, dragged: 4); XCTAssertEqual(w.effectivePages, [0, 1]); XCTAssertTrue(w.recipes[1] != nil)
    }
    @MainActor func testProjectRoundTripAndRecovery() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let w = Workspace(storage: folder); w.document = fixture(); w.selectPage(2); w.mode = "Image"; w.title = "恢复测试"
        var adjustments = ImageAdjustments(); adjustments.brightness = 0.25; adjustments.cropRect = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        w.imageDrafts[2] = adjustments; w.dirty = true
        let archive = try w.snapshot(); let file = folder.appendingPathComponent("test.kongfolio"); try archive.write(file)
        let read = try ProjectArchive.read(file); XCTAssertEqual(read.title, "恢复测试"); XCTAssertEqual(read.drafts[2], adjustments)
        XCTAssertTrue(w.flushRecovery())
        let restored = Workspace(storage: folder); restored.bootstrap()
        XCTAssertEqual(restored.count, 3); XCTAssertEqual(restored.selection, 2); XCTAssertEqual(restored.imageDrafts[2], adjustments); XCTAssertTrue(restored.dirty)
        var bad = archive; bad.version = 99; XCTAssertThrowsError(try bad.validate())
        bad = archive; bad.pdf = Data("bad".utf8); XCTAssertThrowsError(try bad.validate())
        // A serial flush waits for older writes, then commits the most recent snapshot.
        let writer = RecoveryWriter(); writer.write(archive, to: file) { _ in }
        var newer = archive; newer.title = "最新恢复副本"; try writer.flush(newer, to: file)
        XCTAssertEqual(try ProjectArchive.read(file).title, "最新恢复副本")
    }
    @MainActor func testNonDestructiveImageAndCrop() throws {
        let w = Workspace(); w.document = fixture(); let original = w.document.page(at: 0)!.bounds(for: .cropBox)
        w.adjustments.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.5)
        w.adjustments.straighten = 3; w.updatePreview(); XCTAssertTrue(w.preview != nil)
        w.applyImage(); XCTAssertTrue(w.recipes[0] != nil); XCTAssertTrue(w.imageDrafts.isEmpty)
        w.restoreOriginalPage(); XCTAssertEqual(w.page!.bounds(for: .cropBox), original)
        w.undo(); XCTAssertTrue(w.recipes[0] != nil)
    }
    func testPerspectiveAndCropGeometry() throws {
        let doc = fixture(); let cg = try DocumentServices.render(doc.page(at: 0)!, maxDimension: 600)
        var options = ImageAdjustments(); options.cropRect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4)
        let cropped = try DocumentServices.adjusted(cg, options)
        XCTAssertEqual(Double(cropped.width), Double(cg.width) * 0.5, accuracy: 2)
        XCTAssertEqual(Double(cropped.height), Double(cg.height) * 0.4, accuracy: 2)
        options.cropRect = nil; options.perspective = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.85), CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.2, y: 0.15)]
        let corrected = try DocumentServices.adjusted(cg, options); XCTAssertTrue(corrected.width > 0 && corrected.height > 0)
    }
    @MainActor func testAnnotationEditAndUndo() throws {
        let w = Workspace(); w.document = fixture()
        let a = PDFAnnotation(bounds: CGRect(x: 30, y: 40, width: 100, height: 40), forType: .freeText, withProperties: nil)
        a.contents = "Before"; a.font = NSFont(name: "Helvetica", size: 12); w.page!.addAnnotation(a); w.selectAnnotation(a)
        w.note = "After"; w.updateAnnotation(); XCTAssertEqual(a.contents, "After")
        w.resizeAnnotation(2); XCTAssertEqual(a.bounds.width, 200)
        w.deleteAnnotation(); XCTAssertEqual(w.page!.annotations.count, 0)
        w.undo(); XCTAssertEqual(w.page!.annotations.first!.contents, "After")
    }
    func testDetectPaper() throws {
        let ctx = CGContext(data: nil, width: 1000, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1200))
        ctx.move(to: CGPoint(x: 140, y: 150)); ctx.addLine(to: CGPoint(x: 830, y: 190)); ctx.addLine(to: CGPoint(x: 880, y: 1080)); ctx.addLine(to: CGPoint(x: 100, y: 1010)); ctx.closePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        let image = ctx.makeImage()!, points = try DocumentServices.detectPaper(image)
        XCTAssertEqual(points.count, 4)
        XCTAssertTrue(points[0].y > points[3].y && points[1].x > points[0].x)
        var values = ImageAdjustments(); values.perspective = points
        let corrected = try DocumentServices.adjusted(image, values)
        XCTAssertTrue(corrected.width > 500 && corrected.height > 700)
    }
    @MainActor func testSignatureLibraryRoundTrip() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let w = Workspace(storage: folder); w.document = fixture()
        let ink = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 40), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.move(to: .zero); path.line(to: CGPoint(x: 90, y: 30)); ink.add(path); ink.userName = "KongFolio Signature"; w.page!.addAnnotation(ink)
        w.saveSignature(); XCTAssertEqual(w.signatures.count, 1)
        let reader = Workspace(storage: folder); reader.bootstrap(); reader.document = fixture()
        XCTAssertEqual(reader.signatures.count, 1); reader.insertSignature(reader.signatures[0])
        XCTAssertEqual(reader.page!.annotations.count, 1)
        let annotation = reader.page!.annotations[0]; AnnotationGeometry.scale(annotation, by: 2)
        XCTAssertTrue(annotation.paths?.first?.bounds.width == 180)
    }
    func testOCRPreservesRotatedCroppedVisualContent() throws {
        for rotation in [0, 90, 180, 270] {
            let source = fixture(); let original = source.page(at: 0)!
            original.rotation = rotation; original.setBounds(CGRect(x: 10, y: 20, width: 240, height: 300), for: .cropBox)
            let before = try DocumentServices.render(original, maxDimension: 300)
            let newPage = try DocumentServices.searchablePage(original, lines: [RecognizedLine(text: "Searchable", box: CGRect(x: 0.2, y: 0.8, width: 0.5, height: 0.04))])
            let doc = PDFDocument(); doc.insert(newPage, at: 0)
            let after = try DocumentServices.render(newPage, maxDimension: 300)
            XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
            let a = rgba(before), b = rgba(after)
            let difference = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertTrue(difference < 3)
        }
    }
    private func rgba(_ cg: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: cg.width * cg.height * 4))
    }
    func testBatchAndCompressionOutputs() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = fixture().dataRepresentation()!
        let split = try BackgroundJobs.run(JobSpec(operation: .split, source: source, pages: [0, 2], destination: folder, revision: UUID())) { _ in }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: split.destination!.path).count, 2)
        XCTAssertEqual(PDFDocument(url: split.destination!.appendingPathComponent("page-0003.pdf"))!.pageCount, 1)
        let compact = folder.appendingPathComponent("compressed.pdf")
        _ = try BackgroundJobs.run(JobSpec(operation: .compress, source: source, pages: [0, 1, 2], destination: compact, revision: UUID())) { _ in }
        XCTAssertEqual(PDFDocument(url: compact)!.pageCount, 3)
    }
    func testCancelLeavesNoPartialExport() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let spec = JobSpec(operation: .split, source: fixture().dataRepresentation()!, pages: [0, 1, 2], destination: folder, revision: UUID())
        let gate = TestGate(), box = TestTaskBox()
        let task = Task.detached { () throws -> JobResult in
            await gate.wait()
            return try BackgroundJobs.run(spec) { _ in box.cancel() }
        }
        box.task = task; await gate.open()
        do { _ = try await task.value; XCTAssertTrue(false) } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 0)
    }
}
final class TestTaskBox: @unchecked Sendable {
    var task: Task<JobResult, Error>?
    func cancel() { task?.cancel() }
}

actor TestGate {
    var opened = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if opened { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
