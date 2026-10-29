import XCTest
import SwiftUI
import AppKit
import PDFKit
@testable import KongFolio

final class Research040LifecycleTests: XCTestCase {
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
