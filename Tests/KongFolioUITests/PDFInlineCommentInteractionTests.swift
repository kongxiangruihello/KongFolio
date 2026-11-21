import AppKit
import PDFKit
import XCTest
@testable import KongFolio

final class PDFInlineCommentInteractionTests: XCTestCase {
    @MainActor func testSingleClickOpensCommentAndEditToolCanStillDragIt() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root)
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 500, height: 500), for: .mediaBox)
        workspace.document.insert(page, at: 0)
        let anchor = CGRect(x: 70, y: 275, width: 32, height: 14)
        XCTAssertTrue(workspace.saveInlineComment("评论", page: page, anchor: anchor))
        let card = try XCTUnwrap(page.annotations.first)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 650, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DrawingPDFView(frame: window.contentLayoutRect)
        window.contentView = view
        view.document = workspace.document
        view.workspace = workspace
        workspace.pdfView = view
        view.autoScales = true
        window.orderFront(nil)
        view.go(to: page)
        view.layoutDocumentView()
        defer { view.dismissCommentEditor(); window.close() }

        let center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        let position = view.convert(view.convert(center, from: page), to: nil)
        func mouse(_ kind: NSEvent.EventType, at location: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                                            timestamp: 1, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, at: position))
        XCTAssertNil(view.commentEditor)
        view.mouseUp(with: try mouse(.leftMouseUp, at: position))
        XCTAssertNotNil(view.commentEditor)
        view.dismissCommentEditor()

        workspace.selectTool(.edit)
        view.mouseDown(with: try mouse(.leftMouseDown, at: position))
        view.mouseUp(with: try mouse(.leftMouseUp, at: position))
        XCTAssertNotNil(view.commentEditor)
        view.dismissCommentEditor()

        let origin = card.bounds.origin
        let destination = CGPoint(x: position.x + 24, y: position.y + 10)
        view.mouseDown(with: try mouse(.leftMouseDown, at: position))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: destination))
        view.mouseUp(with: try mouse(.leftMouseUp, at: destination))
        XCTAssertNil(view.commentEditor)
        XCTAssertNotEqual(card.bounds.origin, origin)
    }
}
