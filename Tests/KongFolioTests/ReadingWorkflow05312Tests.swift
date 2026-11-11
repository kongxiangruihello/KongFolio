import XCTest
import PDFKit
import AppKit
@testable import KongFolio

final class ReadingWorkflow05312Tests: XCTestCase {
    private func scan(_ position: CGFloat) -> PDFPage {
        let context = CGContext(data:nil,width:360,height:480,bitsPerComponent:8,bytesPerRow:0,
                                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray:1,alpha:1)
        context.fill(CGRect(x:0,y:0,width:360,height:480))
        context.setFillColor(gray:0,alpha:1)
        context.fill(CGRect(x:30,y:position,width:270,height:40))
        return PDFPage(image:NSImage(cgImage:context.makeImage()!,size:NSSize(width:360,height:480)))!
    }

    private func write(_ pages: [PDFPage], to file: URL) throws {
        let document = PDFDocument()
        for (index,page) in pages.enumerated() {
            document.insert(try XCTUnwrap(page.copy() as? PDFPage),at:index)
        }
        XCTAssertTrue(document.write(to:file))
    }

    @MainActor func testMovedScanPageRecoversButDuplicateScansRequireReview() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let first = root.appendingPathComponent("原扫描件.pdf")
        let moved = root.appendingPathComponent("改名并插页.pdf")
        let duplicate = root.appendingPathComponent("相似扫描件.pdf")
        try write([scan(50),scan(190)],to:first)
        let original = try XCTUnwrap(PDFDocument(url:first))
        let page = try XCTUnwrap(original.page(at:1))
        let fingerprint = try XCTUnwrap(ReadingSourceRecovery.fingerprint(page))
        let digest = try FileBaseline.capture(first).digest
        let tracking = ReadingSourceIdentity053(documentID:UUID(),capturedPage:1,pageFingerprint:nil,
                                                capturedPageLabel:nil,visualFingerprint:fingerprint)
        let citation = ReadingCitation(source:SourceRef(path:first.path,fileName:first.lastPathComponent,page:1,fingerprint:digest),
                                       title:"原扫描件",tracking:tracking)

        try write([scan(320),try XCTUnwrap(original.page(at:0)),page],to:moved)
        let recovered = try ReadingSourceRecovery.inspect(ReadingSourceInput(url:moved),citation:citation,quote:"")
        XCTAssertEqual(recovered.exact?.index,2)

        try write([scan(320),page,page],to:duplicate)
        let uncertain = try ReadingSourceRecovery.inspect(ReadingSourceInput(url:duplicate),citation:citation,quote:"")
        XCTAssertNil(uncertain.exact)
        XCTAssertEqual(uncertain.candidates.map(\.index),[1,2])
    }

    @MainActor func testRelocatedTextReturnsTheMatchedLineCoordinates() throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let file = folder.appendingPathComponent("修订后.pdf")
        let document = try TextImport.render("A unique historical passage",markdown:false)
        document.insert(scan(190),at:0)
        XCTAssertTrue(document.write(to:file))
        let source = SourceRef(path:"/old.pdf",fileName:"原文.pdf",page:0,anchor:"unique historical passage")
        let result = try ReadingSourceRecovery.inspect(ReadingSourceInput(url:file),citation:ReadingCitation(source:source,title:"原文"),quote:"")
        let found = try XCTUnwrap(result.exact)
        XCTAssertEqual(found.index,1)
        XCTAssertFalse(found.passage.isEmpty)
        let text = try TextImport.render("Same phrase\nSame phrase",markdown:false)
        XCTAssertTrue(ReadingSourceRecovery.passageRects(try XCTUnwrap(text.page(at:0)),anchor:"Same phrase").isEmpty)
    }

    @MainActor func testReadingSourceRegistryKeepsIdentityWhenPDFMoves() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("原书.pdf")
        let subfolder = root.appendingPathComponent("归档")
        try FileManager.default.createDirectory(at:subfolder,withIntermediateDirectories:true)
        let renamed = subfolder.appendingPathComponent("新书名.pdf")
        try write([scan(50)],to:source)
        let registry = ReadingDocumentRegistry053.shared(root)
        let baseline = try FileBaseline.capture(source)
        let original = registry.identity(source.path,digest:baseline.digest)
        try FileManager.default.moveItem(at:source,to:renamed)
        XCTAssertEqual(ReadingBookIdentity.key(registry.resolve(source.path,documentID:original.id)),
                       ReadingBookIdentity.key(renamed.path))
        let resolved = registry.identity(renamed.path,digest:baseline.digest)
        XCTAssertEqual(resolved.id,original.id)
    }

    @MainActor func testReturningFromSearchRestoresTheSameNoteAndPDFSearchFollowsTab() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let first = try XCTUnwrap(store.activeWorkspace)
        let second = store.addWorkspace()
        let source = try PDFTextSnapshot053Tests().fixture(root)
        let bytes = try Data(contentsOf:source)
        first.load([source],prepared:.documents([bytes]))
        second.load([source],prepared:.documents([bytes]))
        store.select(first.id)
        store.newReadingNote()
        let noteID = try XCTUnwrap(store.readingRecordID)
        store.journal.editRecord(noteID) { $0.note = "保留编辑位置" }
        first.search = "第一份文献的关键词"
        second.search = "第二份文献的关键词"
        XCTAssertTrue(store.openPDFSearch())
        store.select(second.id)
        XCTAssertTrue(store.rightPDFSearchWorkspace === second)
        XCTAssertEqual(second.search,"第二份文献的关键词")
        store.select(first.id)
        XCTAssertTrue(store.rightPDFSearchWorkspace === first)
        XCTAssertEqual(first.search,"第一份文献的关键词")
        store.readingRecordID = nil
        store.showReadingPanel(.notes)
        XCTAssertEqual(store.readingRecordID,noteID)
    }

    @MainActor func testEvictedSearchResumesTheSelectedHit() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try PDFTextSnapshot053Tests().fixture(root)
        let bytes = try Data(contentsOf:file)
        let workspace = Workspace(storage:root)
        workspace.load([file],prepared:.documents([bytes]))
        let query = "FindPage2Only"
        workspace.search = query
        workspace.searchResults = try ReadingServices.search(bytes,query:query)
        workspace.searchCursor = 0
        workspace.clearDocument(keepingSource:true)
        workspace.load([file],prepared:.documents([bytes]))
        workspace.resumePDFSearchIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while workspace.searchTask != nil && Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertEqual(workspace.search,query)
        let cursor = try XCTUnwrap(workspace.searchCursor)
        XCTAssertEqual(workspace.searchResults[cursor].page,1)
    }

    @MainActor func testImageCaptureQueuesRecognitionOnlyForTheSavedRecord() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let source = try PDFTextSnapshot053Tests().fixture(root)
        workspace.load([source],prepared:.documents([try Data(contentsOf:source)]))
        let png = try XCTUnwrap(SignatureImage.pngData(SignaturePositionTests().square()))
        let page = try XCTUnwrap(workspace.document.page(at:0))
        store.startReadingRegionCapture(ocr:.traditional)
        workspace.excerptRegion(imageData:png,size:CGSize(width:20,height:20),page:page,pageRect:CGRect(x:12,y:30,width:20,height:20))
        let record = try XCTUnwrap(store.journal.record(store.readingRecordID))
        XCTAssertEqual(store.readingImageOCRRequest,ReadingImageOCRRequest(recordID:record.id,mode:.traditional))
        XCTAssertNotNil(record.imageAsset)
        XCTAssertEqual(record.citations.first?.source.page,0)
        XCTAssertNil(workspace.readingRegionOCRMode)
    }

    func testExportsKeepBodyTimeAndBothSourcesInThreeFormats() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let first = ReadingCitation(source:SourceRef(path:"/tmp/book1.pdf",fileName:"book1.pdf",page:2),title:"文献甲")
        let second = ReadingCitation(source:SourceRef(path:"/tmp/book2.pdf",fileName:"book2.pdf",page:7),title:"文献乙")
        let record = ReadingRecord(kind:.note,title:"摘读标题",note:"保留笔记正文",citations:[first,second])
        let profile = try XCTUnwrap(ReadingExportProfile.presets.first { $0.name == "正文与出处" })
        let snapshot = ReadingExportSnapshot(title:"阅读资料",records:[record],options:profile.options)
        for format in ReadingRecordExport.Format.allCases {
            let file = root.appendingPathComponent("笔记."+format.ext)
            try ReadingRecordExport.write(snapshot,format:format,assets:root,to:file,expected:FileBaseline.capture(file))
            let text: String
            switch format {
            case .markdown: text = try String(contentsOf:file,encoding:.utf8)
            case .pdf: text = try XCTUnwrap(PDFDocument(url:file)?.string)
            case .word:
                let parts = try ReadingExportAudit.storedZIP(Data(contentsOf:file))
                text = String(decoding:try XCTUnwrap(parts["word/document.xml"]),as:UTF8.self)
            }
            for expected in ["保留笔记正文","出处","文献甲","文献乙","记录时间"] {
                XCTAssertTrue(text.contains(expected),"\(format): \(expected)")
            }
        }
    }
}
