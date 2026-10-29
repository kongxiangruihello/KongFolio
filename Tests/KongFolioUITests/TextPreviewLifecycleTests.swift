import XCTest
import AppKit
import SwiftUI
import PDFKit
@testable import KongFolio
final class TextPreviewLifecycleTests: XCTestCase {
    @MainActor func findPDF(_ view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.compactMap(findPDF).first
    }
    @MainActor func testRetiredTextPreviewDropsDocument() async throws {
        _ = NSApplication.shared
        let note = MarkdownNote(storage:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let doc = PDFDocument(); doc.insert(PDFPage(),at:0); note.preview=doc
        let host = NSHostingView(rootView:AnyView(MarkdownPreview(note:note)));host.frame=NSRect(x:0,y:0,width:800,height:700)
        autoreleasepool { host.layoutSubtreeIfNeeded() };try await Task.sleep(nanoseconds:100_000_000)
        let view = try XCTUnwrap(findPDF(host));XCTAssertTrue(view.document === doc)
        host.rootView=AnyView(EmptyView());autoreleasepool {host.layoutSubtreeIfNeeded()};try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(view.document)
    }
}
