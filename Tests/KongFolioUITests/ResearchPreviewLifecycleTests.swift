import XCTest
import SwiftUI
import PDFKit
import AppKit
@testable import KongFolio

final class ResearchPreviewLifecycleTests: XCTestCase {
    @MainActor func find(_ view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.compactMap(find).first
    }
    @MainActor func testResearchComparisonPreviewDetachesItsDocumentOnClose() async throws {
        _ = NSApplication.shared
        let doc = PDFDocument(); doc.insert(PDFPage(),at:0)
        let host = NSHostingView(rootView:AnyView(ResearchPDFPreview(document:doc,page:0)))
        host.frame = NSRect(x:0,y:0,width:600,height:700)
        autoreleasepool { host.layoutSubtreeIfNeeded() }; try await Task.sleep(nanoseconds:80_000_000)
        let view = try XCTUnwrap(find(host)); XCTAssertTrue(view.document === doc)
        host.rootView = AnyView(EmptyView()); autoreleasepool { host.layoutSubtreeIfNeeded() }; try await Task.sleep(nanoseconds:80_000_000)
        XCTAssertNil(view.document)
    }
}
