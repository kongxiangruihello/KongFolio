import XCTest
import PDFKit
import AppKit
import CoreText
@testable import KongFolio

final class VersionFourTests: XCTestCase {
    func fixture() -> PDFDocument { DocumentServicesTests().fixture() }

    func textImage(_ text: String, width: Int, height: Int, fontName: String = "PingFang TC", size: CGFloat = 96, vertical: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if vertical {
            for (index, character) in text.enumerated() {
                ctx.textPosition = CGPoint(x: (CGFloat(width) - size) / 2, y: CGFloat(height) - size * 1.3 * CGFloat(index + 1))
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes)), ctx)
            }
        } else {
            ctx.textPosition = CGPoint(x: 60, y: CGFloat(height) / 2 - size / 3)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
        }
        return ctx.makeImage()!
    }

    // P1: annotation edits are undone without full-document snapshots, and survive snapshot entries around them.
    @MainActor func testAnnotationUndoWithoutSnapshots() throws {
        let w = Workspace(); w.document = fixture()
        let untouched = w.thumbnailKey(1)
        let ink = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 80, height: 40), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.move(to: .zero); path.line(to: CGPoint(x: 70, y: 30)); ink.add(path)
        let firstKey = w.thumbnailKey(0)
        w.page!.addAnnotation(ink); w.recordAnnotationsAdded([ink])
        XCTAssertEqual(w.history.count, 1); XCTAssertFalse(w.history[0].isSnapshot)
        XCTAssertTrue(w.thumbnailKey(0) != firstKey); XCTAssertEqual(w.thumbnailKey(1), untouched)
        let edit = w.beginAnnotationEdit([ink]); ink.bounds.origin = CGPoint(x: 100, y: 120); w.commitAnnotationEdit(edit)
        XCTAssertEqual(w.history.filter(\.isSnapshot).count, 0)
        w.undo(); XCTAssertEqual(Workspace.visibleAnnotations(on: w.page!).first!.bounds.origin, CGPoint(x: 10, y: 10))
        w.undo(); XCTAssertEqual(Workspace.visibleAnnotations(on: w.page!).count, 0)
        w.redo(); w.redo(); XCTAssertEqual(Workspace.visibleAnnotations(on: w.page!).first!.bounds.origin, CGPoint(x: 100, y: 120))
        // A page operation (snapshot) on top; undoing it reloads the PDF, and the annotation entries still apply.
        w.rotate(); XCTAssertTrue(w.history.last!.isSnapshot)
        w.undo(); w.undo()
        XCTAssertEqual(Workspace.visibleAnnotations(on: w.page!).first!.bounds.origin, CGPoint(x: 10, y: 10))
        w.redo(); w.redo(); XCTAssertEqual(w.page!.rotation, 90)
        XCTAssertEqual(Workspace.visibleAnnotations(on: w.page!).first!.bounds.origin, CGPoint(x: 100, y: 120))
    }

    // P1: binary container, legacy JSON compatibility, and content-addressed recovery.
    @MainActor func testBinaryProjectAndIncrementalRecovery() throws {
        let folder = try VersionTwoTests().temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let w = Workspace(storage: folder); w.document = fixture()
        let original = DocumentServices.subset(w.document, indexes: [1]).dataRepresentation()!
        w.recipes[1] = ImageRecipe(originalPDF: original, adjustments: ImageAdjustments())
        w.bibliography = Bibliography(author: "孔子", title: "论语")
        let archive = try w.snapshot()
        let file = folder.appendingPathComponent("project.kongfolio"); try archive.write(file)
        let data = try Data(contentsOf: file), legacy = try JSONEncoder().encode(archive)
        XCTAssertTrue(data.starts(with: ProjectContainer.magic))
        print("probe: project size binary \(data.count) bytes vs legacy JSON \(legacy.count) bytes")
        XCTAssertTrue(data.count < legacy.count)
        let read = try ProjectArchive.read(file)
        XCTAssertEqual(read.pdf, archive.pdf); XCTAssertEqual(read.recipes[1]!.originalPDF, original); XCTAssertEqual(read.reading?.bibliography, w.bibliography)
        let legacyFile = folder.appendingPathComponent("old.kongfolio"); try legacy.write(to: legacyFile)
        XCTAssertEqual(try ProjectArchive.read(legacyFile).title, archive.title)
        let recovery = folder.appendingPathComponent("R.kfrecovery")
        try RecoveryStore.write(archive, to: recovery); XCTAssertEqual(RecoveryStore.blobCount(recovery), 2)
        w.document.page(at: 0)!.rotation = 90; w.edited()
        let second = try w.snapshot(); try RecoveryStore.write(second, to: recovery)
        XCTAssertEqual(RecoveryStore.blobCount(recovery), 2)
        XCTAssertEqual(try ProjectArchive.read(recovery).pdf, second.pdf)
        var broken = data
        broken.replaceSubrange(ProjectContainer.magic.count..<(ProjectContainer.magic.count + 8), with: [UInt8](repeating: 0xFF, count: 8))
        let brokenFile = folder.appendingPathComponent("broken.kongfolio"); try broken.write(to: brokenFile)
        XCTAssertThrowsError(try ProjectArchive.read(brokenFile))
    }

    // P2: traditional Chinese is recognized when selected; OCR renders at the requested DPI.
    func testTraditionalChineseOCRAndDPI() throws {
        let supported = DocumentServices.supportedOCRLanguages
        print("probe: Vision accurate languages = \(supported.joined(separator: ","))")
        XCTAssertTrue(supported.contains("zh-Hant"))
        let image = textImage("學而時習之不亦說乎", width: 1300, height: 300)
        let hant = try DocumentServices.recognize(image, languages: ["zh-Hant", "en-US"]).map(\.text).joined()
        let hans = try DocumentServices.recognize(image, languages: ["zh-Hans", "en-US"]).map(\.text).joined()
        print("probe: zh-Hant OCR = [\(hant)]  zh-Hans OCR = [\(hans)]")
        XCTAssertTrue(hant.contains("學") && hant.contains("習"), "zh-Hant result: \(hant)")
        let page = fixture().page(at: 0)!
        XCTAssertEqual(Double(DocumentServices.ocrPixelDimension(for: page, dpi: 400)), 400.0 * 400 / 72, accuracy: 0.01)
        XCTAssertEqual(Double(DocumentServices.ocrPixelDimension(for: page, dpi: 200)), 1600, accuracy: 0.01)
    }

    func verticalPage(_ columns: [String], size: CGFloat = 90) -> CGImage {
        let width = Int(size * 1.8) * columns.count + 160, height = Int(size * 1.25) * (columns.map(\.count).max() ?? 1) + 160
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Songti TC" as CFString, size, nil)]
        for (index, column) in columns.enumerated() {
            let x = CGFloat(width) - 80 - CGFloat(index + 1) * size * 1.8 + size * 0.4
            for (row, character) in column.enumerated() {
                ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - 80 - size * 1.25 * CGFloat(row + 1) + size * 0.2)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes)), ctx)
            }
        }
        return ctx.makeImage()!
    }

    // P2: vertical columns are read right to left and each character is placed in its own cell.
    func testVerticalTextColumns() throws {
        let columns = ["學而時習之", "不亦說乎有", "朋自遠方來"]
        let image = verticalPage(columns)
        let horizontal = (try? DocumentServices.recognize(image, languages: ["zh-Hant"]))?.map(\.text).joined() ?? "error"
        let layout = VerticalText.layout(try VerticalText.Gray(image))
        print("probe: vertical layout columns=\(layout.count) cells=\(layout.map(\.cells.count))")
        let lines = try DocumentServices.recognizeVertical(image, languages: ["zh-Hant", "zh-Hans"])
        let text = lines.map(\.text).joined()
        let exact = lines.filter { $0.approximate != true }.count
        print("probe: vertical page \(columns.joined(separator: "|")) — VNRecognizeTextRequest alone [\(horizontal)] · column method [\(text)] exact cells \(exact)/\(columns.joined().count)")
        XCTAssertEqual(layout.count, 3)
        XCTAssertTrue(text.contains("學而時習之"), "column method read: \(text)")
        // The first character of the rightmost column sits in the top-right of the page.
        if let first = lines.first, first.approximate != true { XCTAssertTrue(first.box.minX > 0.6 && first.box.minY > 0.6, "first box \(first.box)") }
        // The text layer built from these lines is searchable, including across column breaks.
        let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2)))!
        let searchable = try DocumentServices.searchablePage(page, lines: lines)
        let doc = PDFDocument(); doc.insert(searchable, at: 0)
        let reloaded = PDFDocument(data: doc.dataRepresentation()!)!
        print("probe: vertical text layer string = [\((reloaded.page(at: 0)!.string ?? "").replacingOccurrences(of: "\n", with: "⏎"))]")
        let hits = try ReadingServices.search(reloaded.dataRepresentation()!, query: "时习")
        XCTAssertEqual(hits.count, 1)
    }

    // P2: a page with a stray stamp of text is still OCR'd; real text pages are skipped.
    func testOCRSkipsOnlyRealTextPages() throws {
        let raster = PDFDocument()
        raster.insert(PDFPage(image: NSImage(cgImage: textImage("KongFolio Threshold Check", width: 1400, height: 300, fontName: "Helvetica", size: 80), size: CGSize(width: 700, height: 150)))!, at: 0)
        let stamped = try DocumentServices.searchablePage(raster.page(at: 0)!, lines: [RecognizedLine(text: "p1", box: CGRect(x: 0.9, y: 0.05, width: 0.05, height: 0.05))])
        raster.removePage(at: 0); raster.insert(stamped, at: 0)
        var settings = OCRSettings(); settings.languages = ["en-US"]
        let result = try BackgroundJobs.run(JobSpec(operation: .ocr, source: raster.dataRepresentation()!, pages: [0], revision: UUID(), ocr: settings)) { _ in }
        XCTAssertTrue(PDFDocument(data: result.pdf!)!.string!.contains("Threshold"))
        let again = try BackgroundJobs.run(JobSpec(operation: .ocr, source: result.pdf!, pages: [0], revision: UUID(), ocr: settings)) { _ in }
        XCTAssertTrue(again.regions.isEmpty)
    }

    // P3: optimized PDF keeps text and outline and never leaves temporary files behind.
    func testOptimizedPDFKeepsText() throws {
        let folder = try VersionTwoTests().temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let doc = try VersionThreeTests().fixture()
        var options = ExportOptions(); options.format = .pdf; options.pdfMode = .optimized
        let target = folder.appendingPathComponent("optimized.pdf")
        let result = try ExportServices.run(JobSpec(operation: .configured, source: doc.dataRepresentation()!, pages: [0, 1, 2], destination: target, revision: UUID(), exportOptions: options)) { _ in }
        let output = try XCTUnwrapDocument(PDFDocument(url: target))
        XCTAssertEqual(output.pageCount, 3); XCTAssertTrue(output.string!.contains("KongFolio")); XCTAssertEqual(ReadingServices.outline(output).count, 2)
        // A photo-like page shows whether PDFKit's image options actually shrink a scan.
        let photo = photoPDF(), photoTarget = folder.appendingPathComponent("photo.pdf")
        let photoResult = try ExportServices.run(JobSpec(operation: .configured, source: photo, pages: [0], destination: photoTarget, revision: UUID(), exportOptions: options)) { _ in }
        print("probe: optimized PDF text fixture: \(result.message); photo page: \(photoResult.message)")
        let estimate = try ExportServices.estimate(data: photo, pages: [0], options: options)
        XCTAssertTrue(estimate.exact && estimate.bytes > 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".KongFolio") }.count, 0)
    }

    func XCTUnwrapDocument(_ document: PDFDocument?) throws -> PDFDocument {
        guard let document else { throw FolioError(message: "missing document") }
        return document
    }

    func photoPDF() -> Data {
        let width = 1600, height = 1200
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 7
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 1664525 &+ 1013904223
            let i = (y * width + x) * 4, noise = Int(seed >> 28)
            pixels[i] = UInt8((x * 255 / width + noise) & 255); pixels[i + 1] = UInt8((y * 255 / height + noise) & 255); pixels[i + 2] = UInt8(((x + y) / 12 + noise) & 255)
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 450)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.draw(image, in: box); ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    // P3: converting a page with text to an image asks first, and declining leaves the page untouched.
    @MainActor func testLossyImageApplyAsksFirst() throws {
        var asked: [String] = []
        Workspace.confirmationHandler = { title, _ in asked.append(title); return false }
        defer { Workspace.confirmationHandler = nil }
        let w = Workspace(); w.document = try VersionThreeTests().fixture(); w.mode = .image
        w.adjustments.brightness = 0.1; w.updatePreview()
        w.applyImage()
        XCTAssertEqual(asked.count, 1); XCTAssertTrue(w.recipes.isEmpty); XCTAssertTrue(w.page!.string!.contains("KongFolio"))
    }

    // P4: search ignores line breaks inside CJK text and matches traditional with simplified.
    func testSearchAcrossLineBreaksAndScripts() {
        var cache: [String: String] = [:]
        let text = "子曰：學而時\n習之，不亦說乎"
        let ranges = ReadingServices.matches(in: text, query: "时习", cache: &cache)
        XCTAssertEqual(ranges.count, 1)
        if let first = ranges.first { XCTAssertEqual((text as NSString).substring(with: first), "時\n習") }
        XCTAssertEqual(ReadingServices.matches(in: text, query: "學而", simplify: false, cache: &cache).count, 1)
        XCTAssertEqual(ReadingServices.matches(in: text, query: "学而", simplify: false, cache: &cache).count, 0)
        XCTAssertEqual(ReadingServices.matches(in: "Search the\nsearch", query: "THE SEARCH", cache: &cache).count, 1)
    }

    // P4: printed page labels and bibliography appear in the exported notes.
    func testNotesUsePrintedPageLabelsAndCitation() {
        let notes = [AnnotationNote(page: 26, index: 0, kind: "高亮", quote: "學而時習之", note: "开篇", label: "15")]
        let bibliography = Bibliography(author: "杨伯峻", title: "论语译注", publisher: "中华书局", year: "1980")
        let markdown = ReadingServices.markdown(title: "论语", notes: notes, bibliography: bibliography)
        XCTAssertTrue(markdown.contains("## 第 27 页（印刷页码 15）"))
        XCTAssertTrue(markdown.contains("引用：杨伯峻：《论语译注》，中华书局，1980，第 15 页。"))
        XCTAssertTrue(markdown.contains("书目：杨伯峻：《论语译注》，中华书局，1980"))
    }

    // P5: popups are not user annotations; opening during a task is queued, not dropped.
    @MainActor func testPopupsHiddenAndBusyOpenQueued() throws {
        let doc = fixture()
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 28, height: 28), forType: .text, withProperties: nil)
        note.contents = "注"; doc.page(at: 0)!.addAnnotation(note)
        let w = Workspace(); w.document = PDFDocument(data: doc.dataRepresentation()!)!
        XCTAssertEqual(w.currentAnnotations.count, 1)
        w.busy = true
        w.load([URL(fileURLWithPath: "/tmp/queued.pdf")])
        XCTAssertTrue(w.status.contains("queued.pdf")); XCTAssertEqual(w.count, 3)
    }

    // P5: page metadata follows page moves through a single remap.
    @MainActor func testPageMetaFollowsPages() throws {
        let w = Workspace(); w.document = fixture()
        w.ocrRegions[2] = [RecognizedLine(text: "x", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))]
        w.imageDrafts[0] = ImageAdjustments()
        w.selectedPages = [2]; w.selection = 2; w.movePages(before: 0, dragged: 2)
        XCTAssertTrue(w.ocrRegions[0] != nil); XCTAssertTrue(w.imageDrafts[1] != nil); XCTAssertEqual(w.pageMeta.count, 3)
        w.remove(); XCTAssertEqual(w.pageMeta.count, 2); XCTAssertTrue(w.ocrRegions.isEmpty)
    }

    // OCR text layers can extract as Kangxi radicals (⾃, ⽽); search and export map them back.
    func testCompatibilityIdeographsInTextLayer() throws {
        XCTAssertEqual(ReadingServices.repairIdeographs("⾃⽽⽅，"), "自而方，")
        let page = fixture().page(at: 0)!
        let searchable = try DocumentServices.searchablePage(page, lines: [RecognizedLine(text: "學而時習之自遠方來", box: CGRect(x: 0.05, y: 0.5, width: 0.9, height: 0.08))])
        let doc = PDFDocument(); doc.insert(searchable, at: 0)
        let data = doc.dataRepresentation()!
        print("probe: horizontal text layer string = [\(PDFDocument(data: data)!.string ?? "")]")
        XCTAssertEqual(try ReadingServices.search(data, query: "学而").count, 1)
        XCTAssertEqual(try ReadingServices.search(data, query: "自远方").count, 1)
    }
}
