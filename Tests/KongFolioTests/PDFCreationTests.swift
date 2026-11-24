import XCTest
import PDFKit
import CoreText
@testable import KongFolio

@MainActor final class PDFCreationTests: XCTestCase {
    private func store() -> WorkspaceStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFCreationTests-" + UUID().uuidString)
        return WorkspaceStore(storage: root, readingDefaults: UserDefaults(suiteName: "PDFCreationTests." + UUID().uuidString)!)
    }

    func testUntouchedNewPDFClosesWithoutDestinationOrRecovery() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        let workspace = store.newPDF()
        XCTAssertTrue(workspace.dirty)
        XCTAssertTrue(workspace.canDiscardEmptyCreation)
        let finished = await workspace.finishPendingSave()
        XCTAssertTrue(finished)
        XCTAssertFalse(workspace.dirty)
        XCTAssertNil(workspace.sourceURL)
        XCTAssertNil(workspace.projectURL)
        XCTAssertTrue(workspace.closeDocument())
        XCTAssertEqual(workspace.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.recoveryURL.path))
    }

    func testLegacyUnmarkedBlankPDFCanCloseWithoutDiscardingDrawnContent() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        let legacy = store.newPDF()
        legacy.emptyCreationPDF = nil
        XCTAssertTrue(legacy.canDiscardEmptyCreation)
        let renderedPaper = try store.adoptCreatedPDF(PDFCreationService.blank(PDFCreationOptions()), title: "绘图结果")
        XCTAssertFalse(renderedPaper.canDiscardEmptyCreation)
    }

    func testMakingPDFKeepsPageOrderAndTextWhenSaved() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store.storage) }
        let workspace = store.newPDF()
        XCTAssertTrue(workspace.isMakingPDF)
        workspace.beginMakingText()
        XCTAssertEqual(workspace.tool, .textBox)
        let cover = try XCTUnwrap(workspace.page)
        let title = PDFAnnotation(bounds: CGRect(x: 40, y: 80, width: 180, height: 30), forType: .freeText, withProperties: nil)
        title.contents = "讲义封面"
        cover.addAnnotation(title)
        workspace.recordAnnotationsAdded([title])
        workspace.insertBlankPage()
        XCTAssertTrue(workspace.movePages([0], before: 2))
        workspace.undo()
        XCTAssertTrue(workspace.isMakingPDF)
        workspace.redo()
        let url = store.storage.appendingPathComponent("讲义.pdf")
        try workspace.writePDFCopy(to: url)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertTrue(saved.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertEqual(saved.page(at: 1)?.annotations.first?.contents, "讲义封面")
        XCTAssertTrue(workspace.discardWork())
        XCTAssertTrue(workspace.closeDocument())
        XCTAssertFalse(workspace.isMakingPDF)
    }

    func testTemplatePaperCanCloseButTextAnnotationRequiresSaving() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        var options = PDFCreationOptions(); options.pattern = .cornell; options.pageCount = 3
        let workspace = try store.adoptCreatedPDF(PDFCreationService.blank(options), title: "研究笔记", emptyPaper: true)
        XCTAssertTrue(workspace.canDiscardEmptyCreation)
        let annotation = PDFAnnotation(bounds: CGRect(x: 80, y: 120, width: 120, height: 40), forType: .freeText, withProperties: nil)
        annotation.contents = "写下的内容"
        workspace.document.page(at: 0)?.addAnnotation(annotation)
        XCTAssertFalse(workspace.canDiscardEmptyCreation)
        workspace.edited()
        XCTAssertFalse(workspace.canDiscardEmptyCreation)
    }

    func testPrivateReadingDataAndExternalBlankFilesRemainProtected() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        let workspace = store.newPDF()
        workspace.sourceURL = store.storage.appendingPathComponent("原文件.pdf")
        XCTAssertFalse(workspace.canDiscardEmptyCreation)
        workspace.sourceURL = nil
        workspace.bookmarks = [PageBookmark(page: 0, label: "重要页")]
        XCTAssertFalse(workspace.canDiscardEmptyCreation)
        let converted = try store.adoptCreatedPDF(PDFCreationService.blank(PDFCreationOptions()), title: "转换结果")
        XCTAssertFalse(converted.canDiscardEmptyCreation)
    }

    func testRecoveredUntouchedPaperRetainsItsCloseBehavior() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        let workspace = store.newPDF()
        let original = try workspace.snapshot()
        let decoded = try JSONDecoder().decode(ProjectArchive.self, from: JSONEncoder().encode(original))
        let recovered = store.addWorkspace()
        try recovered.restore(decoded)
        XCTAssertTrue(recovered.canDiscardEmptyCreation)
        XCTAssertTrue(recovered.prepareToClose())
        XCTAssertFalse(recovered.dirty)
    }

    func testPaperSizesOrientationAndMultiplePagesSurvivePDFEncoding() throws {
        for paper in PDFPaperSize.allCases where paper != .custom {
            let size = try XCTUnwrap(paper.points)
            var options = PDFCreationOptions()
            options.width = size.height; options.height = size.width; options.pageCount = 3
            let document = try XCTUnwrap(PDFDocument(data: PDFCreationService.blank(options)))
            XCTAssertEqual(document.pageCount, 3)
            let bounds = try XCTUnwrap(document.page(at: 2)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, size.height, accuracy: 0.1)
            XCTAssertEqual(bounds.height, size.width, accuracy: 0.1)
        }
    }

    func testPatternsProduceDistinctVisiblePaperAndSearchableEmptyPages() throws {
        var images = Set<Data>()
        for pattern in PDFPaperPattern.allCases {
            var options = PDFCreationOptions(); options.pattern = pattern
            options.color = PDFCreationColor(red: 0.99, green: 0.96, blue: 0.86)
            let document = try XCTUnwrap(PDFDocument(data: PDFCreationService.blank(options)))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertTrue((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let image = page.thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)
            images.insert(try XCTUnwrap(image.tiffRepresentation))
        }
        XCTAssertEqual(images.count, PDFPaperPattern.allCases.count)
    }

    func testInvalidDimensionsMarginsAndPageCountsAreRejected() {
        var options = PDFCreationOptions(); options.width = .nan
        XCTAssertThrowsError(try PDFCreationService.blank(options))
        options = PDFCreationOptions(); options.pageCount = 201
        XCTAssertThrowsError(try PDFCreationService.blank(options))
        options = PDFCreationOptions(); options.left = options.width
        XCTAssertThrowsError(try PDFCreationService.blank(options))
        options = PDFCreationOptions(); options.spacing = 0
        XCTAssertThrowsError(try PDFCreationService.blank(options))
    }

    func testFileCombinationPreservesSelectedOrderAndLeavesOriginalsIntact() async throws {
        let store = store()
        let root = store.storage
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.pdf")
        let second = root.appendingPathComponent("second.txt")
        let original = try TextImport.render("第一份 FIRST", markdown: false).dataRepresentation().unwrap("fixture")
        try original.write(to: first)
        try "第二份 SECOND".write(to: second, atomically: true, encoding: .utf8)
        let data = try await PDFCreationService.combine([second, first])
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("SECOND") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("FIRST") == true)
        XCTAssertEqual(try Data(contentsOf: first), original)
    }

    func testWebPaginationPreservesTopAndBottomTextAcrossPageBreaks() throws {
        let buffer = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 480, height: 1800)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: buffer)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for (text, y) in [("TOP", CGFloat(1760)), ("BOTTOM", CGFloat(50))] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 20, y: y); CTLineDraw(line, context)
        }
        context.endPDFPage(); context.closePDF()
        let options = PDFCreationOptions()
        let document = try XCTUnwrap(PDFDocument(data: PDFCreationService.paginate(buffer as Data, options: options)))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("TOP") == true)
        XCTAssertTrue(document.page(at: 2)?.string?.contains("BOTTOM") == true)
    }

    func testClipboardSnapshotsPlainTextAndPDFWithoutUsingGeneralClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("剪贴板笔记 CLIPBOARD", forType: .string)
        let snapshot = try XCTUnwrap(PDFCreationClipboard.read(pasteboard))
        pasteboard.clearContents()
        let document = try XCTUnwrap(PDFDocument(data: snapshot.pdf()))
        XCTAssertTrue(document.string?.contains("CLIPBOARD") == true)
        pasteboard.setData(try PDFCreationService.blank(PDFCreationOptions()), forType: .pdf)
        let pdf = try XCTUnwrap(PDFCreationClipboard.read(pasteboard))
        XCTAssertTrue(pdf.summary.contains("1"))
    }

    func testOptionsRememberPaperSettingsAndIgnoreInvalidSavedValues() throws {
        let defaults = UserDefaults(suiteName: "PDFCreationOptionsTests." + UUID().uuidString)!
        var options = PDFCreationOptions(); options.pattern = .dotted; options.pageCount = 5
        options.save(defaults)
        XCTAssertEqual(PDFCreationOptions.load(defaults), options)
        options.pageCount = 0
        defaults.set(try JSONEncoder().encode(options), forKey: PDFCreationOptions.settingsKey)
        XCTAssertEqual(PDFCreationOptions.load(defaults), PDFCreationOptions())
    }

    func testScannerDelegateImplementsNativeCompletionSelector() {
        let delegate = PDFScannerView.Coordinator(onFile: { _ in }, onError: { _ in })
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("scannerDeviceView:didScanToURL:fileData:error:")))
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("scannerDeviceView:didEncounterError:")))
    }
}
