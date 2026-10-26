import XCTest
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import KongFolio

final class Release024Tests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kf024-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor func testDrawingStylePersistsPerToolAcrossWorkspaces() throws {
        let name = "kf024-style-"+UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = Workspace(drawingDefaults: defaults)
        first.selectTool(.line)
        first.penWidth = 5; first.lineDashed = true; first.shapeFill = true
        first.chooseAnnotationColor(.blue)
        first.selectTool(.rectangle)
        first.penWidth = 8
        let second = Workspace(drawingDefaults: defaults)
        second.selectTool(.line)
        XCTAssertEqual(second.penWidth, 5)
        XCTAssertTrue(second.lineDashed)
        XCTAssertTrue(second.shapeFill)
        let color = NSColor(second.annotationColor).usingColorSpace(.sRGB)!
        XCTAssertTrue(color.blueComponent > 0.8)
        second.selectTool(.rectangle)
        XCTAssertEqual(second.penWidth, 8)
        second.showAnnotationBar = false
        second.showAnnotationBar = true
        XCTAssertEqual(second.tool, .rectangle)
        XCTAssertEqual(second.penWidth, 8)
    }
    @MainActor func testAnnotationIdentitySurvivesPDFSerialization() throws {
        let document = DocumentServicesTests().fixture()
        let annotation = PDFAnnotation(bounds: CGRect(x:10,y:10,width:50,height:50),forType:.ink,withProperties:nil)
        let path = NSBezierPath(); path.move(to:.zero);path.line(to:CGPoint(x:30,y:30));annotation.add(path)
        document.page(at:0)!.addAnnotation(annotation)
        let id = AnnotationIdentity.id(of:annotation)
        let reloaded = PDFDocument(data: document.dataRepresentation()!)!
        XCTAssertEqual(reloaded.page(at:0)!.annotations.count,1)
        XCTAssertEqual(reloaded.page(at:0)!.annotations.first?.value(forAnnotationKey: AnnotationIdentity.key) as? String,id)
    }
    func testSplitBoxesRespectRotationAndExistingCrop() throws {
        let page = DocumentServicesTests().fixture().page(at: 0)!
        for rotation in [0,90,180,270] {
            page.rotation = rotation
            page.setBounds(CGRect(x:20,y:30,width:200,height:300),for:.cropBox)
            let boxes = ScanProcessing.splitBoxes(page, fraction:0.4)
            XCTAssertEqual(boxes.count,2)
            XCTAssertTrue(abs(boxes[0].width*boxes[0].height / (200*300) - 0.4) < 0.001)
            XCTAssertEqual(boxes[0].union(boxes[1]), page.bounds(for:.cropBox))
        }
    }
    @MainActor func testSplittingKeepsMetadataAndCanUndo() throws {
        let w = Workspace(); w.document = DocumentServicesTests().fixture()
        let note = PDFAnnotation(bounds:CGRect(x:20,y:30,width:20,height:20),forType:.text,withProperties:nil)
        note.contents = "left note"; w.document.page(at:0)!.addAnnotation(note)
        w.bookmarks = [PageBookmark(page:2,label:"last")]
        w.updateMeta(0) { $0.ocrRegions = [RecognizedLine(text:"left",box:CGRect(x:0.1,y:0.2,width:0.2,height:0.1))] }
        try w.splitScannedPages([0],fraction:0.5,rightFirst:false)
        XCTAssertEqual(w.count,4)
        XCTAssertEqual(w.bookmarks.first?.page,3)
        XCTAssertEqual(w.meta(0).ocrRegions?.first?.text,"left")
        XCTAssertTrue(w.document.page(at:0)!.annotations.contains { $0.contents == "left note" })
        XCTAssertTrue(w.meta(1).ocrRegions?.isEmpty == true)
        w.undo()
        XCTAssertEqual(w.count,3)
        XCTAssertEqual(w.bookmarks.first?.page,2)
    }
    func testMedianBaselineRejectsOutliers() {
        let lines = [0.02,0.021,0.019,0.02,0.3].map { slope in (CGPoint(x:0.1,y:0.3),CGPoint(x:0.9,y:0.3+slope)) }
        let angle = ScanProcessing.baselineAngle(lines,size:CGSize(width:1000,height:1000))
        XCTAssertTrue(angle > 1 && angle < 2)
        XCTAssertEqual(ScanProcessing.baselineAngle(Array(lines.prefix(2)),size:CGSize(width:1000,height:1000)),0)
    }
    func testStraighteningKeepsTextAndExpandsBounds() throws {
        let page = try TextImport.render("Searchable straightened page",markdown:false).page(at:0)!
        let original = page.bounds(for:.cropBox)
        let straight = try ScanProcessing.straightened(page,angle:3)
        XCTAssertTrue(straight.bounds(for:.mediaBox).width > original.width)
        XCTAssertTrue(straight.bounds(for:.mediaBox).height > original.height)
        XCTAssertTrue(straight.string?.contains("Searchable") == true)
        XCTAssertThrowsError(try ScanProcessing.straightened(page,angle:Double.nan))
    }
    @MainActor func testDirectSaveWritesAnnotationWithoutPromptAndPreservesRecoveryMetadata() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("source.pdf")
        let w = Workspace(storage:directory); w.bootstrap(); w.document = DocumentServicesTests().fixture()
        try w.document.dataRepresentation()!.write(to:url); w.sourceURL = url
        w.bookmarks = [PageBookmark(page:0,label:"Keep")]
        let note = PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.text,withProperties:nil)
        note.contents = "saved without prompt"; w.document.page(at:0)!.addAnnotation(note)
        w.recordAnnotationsAdded([note])
        XCTAssertTrue(w.saveDirectly(askForDestination:false))
        XCTAssertFalse(w.dirty)
        XCTAssertTrue(PDFDocument(url:url)!.page(at:0)!.annotations.contains { $0.contents == "saved without prompt" })
        XCTAssertFalse(w.canRestoreFromFile)
        XCTAssertTrue(w.prepareToClose())
        XCTAssertTrue(FileManager.default.fileExists(atPath:w.recoveryURL.path))
        XCTAssertEqual(try ProjectArchive.read(w.recoveryURL).reading?.bookmarks.first?.label,"Keep")
    }
    @MainActor func testImageImportAndNewImageNeverOverwritesItsSource() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at:directory) }
        let fixture = DocumentServicesTests().fixture()
        let image = fixture.page(at:0)!.thumbnail(of:CGSize(width:300,height:400),for:.mediaBox).cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let url = directory.appendingPathComponent("image.png")
        let bytes = SignatureImage.pngData(image)!
        try bytes.write(to:url)
        let doc = try DocumentServices.load(url)
        XCTAssertEqual(doc.pageCount,1)
        let w = Workspace(storage:directory);w.document = doc;w.sourceURL = url;w.dirty = true
        XCTAssertFalse(w.saveDirectly(askForDestination:false))
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testMultipageTIFFImportsEveryPage() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan.tiff")
        let source = DocumentServicesTests().fixture()
        let image = source.page(at: 0)!.thumbnail(of: CGSize(width: 200,height: 300),for:.mediaBox).cgImage(forProposedRect:nil,context:nil,hints:nil)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2,nil)!
        CGImageDestinationAddImage(destination,image,nil);CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try ImageImport.document(url).pageCount,2)
    }
    func testInspectionFindsBlankPageWithoutMutatingInput() throws {
        let doc = PDFDocument()
        let page = PDFPage();page.setBounds(CGRect(x:0,y:0,width:300,height:400),for:.mediaBox);doc.insert(page,at:0)
        let bytes = doc.dataRepresentation()!
        let issues = try ScanProcessing.inspect(bytes,pages:[0])
        XCTAssertEqual(issues.count,1)
        XCTAssertTrue(issues[0].reasons.contains("疑似空白页"))
        XCTAssertEqual(doc.pageCount,1)
        XCTAssertTrue(doc.page(at:0)!.annotations.isEmpty)
    }
    @MainActor func testPlainAndHTMLKeepSourceFormatAndBackup() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at:directory) }
        let text = MarkdownNote(text:"**literal**",storage:directory,format:.plain)
        XCTAssertTrue(try text.renderDocument().string!.contains("**literal**"))
        let html = MarkdownNote(text:"<h1>Hello</h1><p>HTML document</p>",dirty:true,storage:directory,format:.html)
        try html.writeBackup()
        let restored = MarkdownNote.restoreBackups(storage:directory)
        XCTAssertEqual(restored.first?.format,.html)
        let url = directory.appendingPathComponent("page.html")
        try html.write(to:url)
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),html.text)
        XCTAssertEqual(try MarkdownNote.open(url,storage:directory).format,.html)
    }
    @MainActor func testMixedFilesRouteTextToEditor() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at:directory) }
        let pdf = directory.appendingPathComponent("a.pdf"), text = directory.appendingPathComponent("a.txt")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to:pdf)
        try "Text editor".write(to:text,atomically:true,encoding:.utf8)
        let store = WorkspaceStore(storage:directory);store.bootstrap()
        store.openEach([text,pdf])
        XCTAssertEqual(store.tabs.compactMap(\.note).count,1)
        XCTAssertEqual(store.activeNote?.format,.plain)
    }
}
