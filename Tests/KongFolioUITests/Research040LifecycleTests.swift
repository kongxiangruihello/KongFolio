import XCTest
import SwiftUI
import AppKit
import PDFKit
@testable import KongFolio

final class Research040LifecycleTests: XCTestCase {
    @MainActor func testThousandBookPeriodicalEditorBuildsBoundedControls() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PeriodicalUI-"+UUID().uuidString)
        let file = root.appendingPathComponent("Library/catalog.json")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let books = (1...1083).map { LibraryBook(path:root.appendingPathComponent("book-\($0).pdf").path,title:"阅读样本 \($0)") }
        try JSONEncoder().encode(BookLibrary.Catalog(books:books)).write(to:file)
        let library = BookLibrary(storage:root), research = ResearchStore(storage:root)
        let host = NSHostingView(rootView:AnyView(PeriodicalBatchEditor(library:library,research:research,controller:ResearchController())))
        host.frame = NSRect(x:0,y:0,width:1060,height:700)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:200_000_000); host.layoutSubtreeIfNeeded()
        func countFields(_ view:NSView) -> Int { (view is NSTextField ? 1 : 0) + view.subviews.reduce(0) { $0 + countFields($1) } }
        let fields = countFields(host)
        XCTAssertGreaterThan(fields,20,"The edit rows must actually render")
        XCTAssertLessThan(fields,250,"The panel must not build thousands of editable text fields at once")
        XCTAssertEqual(library.books.count,1083)
        var canonicalCalls = 0
        let restored = ResearchRestoreRow.prepare(books:books,originals:Set(books.map(\.path)),existing:books) { path in canonicalCalls += 1; return path }
        XCTAssertEqual(canonicalCalls,1083,"Backup preview must normalize each distinct path once, not scan the shelf for every row")
        XCTAssertEqual(restored.count,1083); XCTAssertTrue(restored.allSatisfy { $0.hasOriginal && $0.exists })
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
    }
    @MainActor func testPagePickerDetachesDocumentAndObserverOnExit() async throws {
        _ = NSApplication.shared
        let doc = PDFDocument(); doc.insert(PDFPage(),at:0)
        let host = NSHostingView(rootView:AnyView(ResearchPagePicker(document:doc,page:.constant(0))))
        host.frame = NSRect(x:0,y:0,width:600,height:600)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:60_000_000)
        let view = try XCTUnwrap(ResearchPreviewLifecycleTests().find(host)); XCTAssertTrue(view.document === doc)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:60_000_000)
        XCTAssertNil(view.document)
    }
    @MainActor func testReadingRulerNeverBecomesAPDFAnnotation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RulerTest-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let doc = PDFDocument(); doc.insert(PDFPage(),at:0); let file = root.appendingPathComponent("book.pdf"); try doc.dataRepresentation()!.write(to:file)
        let w = Workspace(storage:root); w.bootstrap(); w.load([file],prepared:.documents([try Data(contentsOf:file)]))
        let host = NSHostingView(rootView:AnyView(PDFCanvas(workspace:w))); host.frame = NSRect(x:0,y:0,width:600,height:700)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:60_000_000)
        w.readingRuler.enabled = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertTrue(w.document.page(at:0)!.annotations.isEmpty)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:60_000_000); XCTAssertNil(w.pdfView)
    }
}
