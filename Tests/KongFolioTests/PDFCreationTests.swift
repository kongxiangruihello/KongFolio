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
        XCTAssertTrue(workspace.placesPDFContentText)
        XCTAssertEqual(workspace.tool, .select)
        let cover = try XCTUnwrap(workspace.page)
        try workspace.addPageContentText("讲义封面 FolioTitle", size: 18, color: .black,
                                         on: cover, at: CGPoint(x: 40, y: 200))
        XCTAssertFalse(workspace.placesPDFContentText)
        XCTAssertFalse(workspace.canDiscardEmptyCreation)
        XCTAssertTrue(workspace.page?.string?.contains("FolioTitle") == true, "写入后：\(String(describing: workspace.page?.string))")
        workspace.insertBlankPage()
        XCTAssertTrue(workspace.document.page(at: 0)?.string?.contains("FolioTitle") == true,
                      "插入页后：\(String(describing: workspace.document.string))")
        XCTAssertTrue(workspace.movePages([0], before: 2))
        XCTAssertTrue(workspace.document.page(at: 1)?.string?.contains("FolioTitle") == true,
                      "重排后：\(String(describing: workspace.document.string))")
        workspace.undo()
        XCTAssertTrue(workspace.isMakingPDF)
        XCTAssertTrue(workspace.document.page(at: 0)?.string?.contains("FolioTitle") == true,
                      "撤销后：\(String(describing: workspace.document.string))")
        workspace.redo()
        XCTAssertTrue(workspace.document.page(at: 1)?.string?.contains("FolioTitle") == true,
                      "重做后：\(String(describing: workspace.document.string))")
        let url = store.storage.appendingPathComponent("讲义.pdf")
        try workspace.writePDFCopy(to: url)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertTrue(saved.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertTrue(saved.page(at: 1)?.annotations.isEmpty == true)
        XCTAssertTrue(StampingTests().compact(saved.page(at: 1)?.string).contains("讲义封面FolioTitle"),
                      "保存后：\(String(describing: saved.string))")
        XCTAssertEqual(saved.findString("FolioTitle", withOptions: []).count, 1)
        workspace.duplicatePages()
        XCTAssertEqual(workspace.count, 3)
        XCTAssertEqual(workspace.document.findString("FolioTitle", withOptions: []).count, 2)
        workspace.remove()
        XCTAssertEqual(workspace.document.findString("FolioTitle", withOptions: []).count, 1)
        XCTAssertTrue(workspace.discardWork())
        XCTAssertTrue(workspace.closeDocument())
        XCTAssertFalse(workspace.isMakingPDF)
    }

    func testSingleClickTextCanBeEditedAfterReopeningSavedPDF() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        try FileManager.default.createDirectory(at: store.storage, withIntermediateDirectories: true)
        let workspace = store.newPDF()
        let blank = try XCTUnwrap(workspace.page)
        try workspace.addPageContentText("OriginalTitle", size: 18, color: .black,
                                         on: blank, at: CGPoint(x: 40, y: 230))
        let url = store.storage.appendingPathComponent("editable.pdf")
        try workspace.writePDFCopy(to: url)
        try SignaturePersistence.write(workspace.signatureEditArchives, pdf: url, storage: store.storage)
        let bytes = try Data(contentsOf: url)
        let reopened = Workspace(storage: store.storage)
        reopened.document = try XCTUnwrap(PDFDocument(data: bytes))
        reopened.restoreSignatureEdits(SignaturePersistence.read(pdf: url, bytes: bytes, storage: store.storage))
        let page = try XCTUnwrap(reopened.page)
        let block = try XCTUnwrap(reopened.signatureEditArchives[0]?.texts?.first)
        let clicked = block.pageRect(CGRect(x: block.bounds.minX + 10, y: block.bounds.midY,
                                           width: 0, height: 0), on: page).origin
        let hit = try XCTUnwrap(reopened.pageTextIndex(at: clicked, on: page))
        reopened.selectPageText(hit, on: page)
        XCTAssertEqual(reopened.selectedPageText?.text, "OriginalTitle")
        let selection = try XCTUnwrap(reopened.pageTextSelection)
        try reopened.updatePageContentText(selection, input: "RevisedTitle", size: 24, color: .blue)
        XCTAssertEqual(reopened.selectedPageText?.size, 24)
        XCTAssertEqual(reopened.selectedPageText?.color, .blue)
        XCTAssertEqual(reopened.document.findString("OriginalTitle", withOptions: []).count, 0)
        XCTAssertEqual(reopened.document.findString("RevisedTitle", withOptions: []).count, 1)
        XCTAssertTrue(reopened.page?.annotations.isEmpty == true)
        XCTAssertThrowsError(try reopened.updatePageContentText(selection, input: "Stale", size: 14, color: .black))
        reopened.undo()
        XCTAssertEqual(reopened.document.findString("OriginalTitle", withOptions: []).count, 1)
        reopened.redo()
        XCTAssertEqual(reopened.document.findString("RevisedTitle", withOptions: []).count, 1)
    }

    func testRearrangedDraftWithOnlyBlankPaperClosesWithoutSaving() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        var options = PDFCreationOptions()
        options.pattern = .cornell
        let workspace = try store.adoptCreatedPDF(PDFCreationService.blank(options), title: "PDF 草稿", emptyPaper: true)
        workspace.insertBlankPage()
        workspace.insertBlankPage()
        XCTAssertTrue(workspace.movePages([0], before: 3))
        guard workspace.canDiscardEmptyCreation else {
            XCTFail("仅含空页及内置底纹的草稿应可直接关闭")
            return
        }
        let finished = await workspace.finishPendingSave()
        XCTAssertTrue(finished)
        XCTAssertNil(workspace.sourceURL)
        XCTAssertFalse(workspace.dirty)
    }

    func testPageTextSurvivesImageRemovalAndKeepsAnnotations() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.storage) }
        let workspace = store.newPDF()
        let initialPage = try XCTUnwrap(workspace.page)
        initialPage.rotation = 90
        workspace.changed()
        let base = try workspace.pdfData()
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(SignatureImage.pngData(image))
        let item = PlacedSignature(id: UUID(), png: png, rect: CGRect(x: 40, y: 50, width: 50, height: 50), isPageImage: true)
        let layer = SignatureLayer(base: base, preserved: true, size: initialPage.bounds(for: .cropBox).size,
                                   rotation: 90, items: [item], page: initialPage)
        let page = try workspace.rebake(layer, items: [item])
        let existing = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 18, height: 18), forType: .text, withProperties: nil)
        existing.contents = "已存在的批注"
        page.addAnnotation(existing)
        workspace.recordAnnotationsAdded([existing])
        try workspace.addPageContentText("RotatedText", size: 14, color: .blue,
                                         on: page, at: CGPoint(x: 90, y: 45))
        XCTAssertEqual(workspace.page?.rotation, 90)
        XCTAssertTrue(workspace.page?.string?.contains("RotatedText") == true)
        workspace.removePlacedSignature(item, in: layer)
        XCTAssertTrue(workspace.page?.string?.contains("RotatedText") == true)
        XCTAssertTrue(workspace.page?.annotations.contains(where: { $0.contents == "已存在的批注" }) == true)
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
