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

        workspace.selectTool(.note)
        let newPosition = view.convert(view.convert(CGPoint(x: 90, y: 130), from: page), to: nil)
        view.mouseDown(with: try mouse(.leftMouseDown, at: newPosition))
        view.mouseUp(with: try mouse(.leftMouseUp, at: newPosition))
        let input = try XCTUnwrap(view.commentEditor)
        XCTAssertTrue(input.superview === view)
        XCTAssertTrue(window.firstResponder === input.textView)
        XCTAssertEqual(page.annotations.count, 1)

        input.textView.insertText("就地输入的评论", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(input.draft.hasText)
        input.draft.style.textColor = 0x254E9E
        input.draft.style.alignment = .center
        XCTAssertEqual(input.textView.alignment, .center)

        func drag(_ handle: PDFCommentDragHandle, x: CGFloat, y: CGFloat) throws {
            view.layoutSubtreeIfNeeded()
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let end = CGPoint(x: start.x + x, y: start.y + y)
            handle.mouseDown(with: try mouse(.leftMouseDown, at: start))
            handle.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
            handle.mouseUp(with: try mouse(.leftMouseUp, at: end))
        }

        let start = input.frame
        try drag(input.moveHandle, x: -25, y: 40)
        let moved = input.frame
        XCTAssertLessThan(moved.minX, start.minX)
        XCTAssertGreaterThan(moved.maxY, start.maxY)
        XCTAssertTrue(input.draft.style.automaticHeight)
        try drag(input.resizeHandle, x: 40, y: -32)
        XCTAssertGreaterThan(input.frame.width, moved.width)
        XCTAssertGreaterThan(input.frame.height, moved.height)
        XCTAssertFalse(input.draft.style.automaticHeight)
        let resized = view.convert(input.frame, to: page)

        XCTAssertTrue(view.commitCommentEditor())
        XCTAssertNil(view.commentEditor)
        let added = try XCTUnwrap(page.annotations.first { $0 !== card })
        XCTAssertEqual(added.contents, "就地输入的评论")
        XCTAssertEqual(PDFInlineComment.style(of: added).textColor, 0x254E9E)
        XCTAssertEqual(added.bounds.minX, resized.minX, accuracy: 1)
        XCTAssertEqual(added.bounds.maxY, resized.maxY, accuracy: 1)
        XCTAssertEqual(added.bounds.width, resized.width, accuracy: 1)
        XCTAssertEqual(added.bounds.height, resized.height, accuracy: 1)

        let savedPosition = view.convert(view.convert(CGPoint(x: added.bounds.midX, y: added.bounds.midY), from: page), to: nil)
        view.mouseDown(with: try mouse(.leftMouseDown, at: savedPosition))
        view.mouseUp(with: try mouse(.leftMouseUp, at: savedPosition))
        let reopened = try XCTUnwrap(view.commentEditor)
        let priorBounds = added.bounds
        try drag(reopened.moveHandle, x: 26, y: -17)
        XCTAssertTrue(view.commitCommentEditor())
        XCTAssertNotEqual(added.bounds.origin, priorBounds.origin)
        XCTAssertEqual(added.bounds.size, priorBounds.size)
        XCTAssertEqual(added.contents, "就地输入的评论")

        let blankPosition = view.convert(view.convert(CGPoint(x: 75, y: 360), from: page), to: nil)
        view.mouseDown(with: try mouse(.leftMouseDown, at: blankPosition))
        XCTAssertNotNil(view.commentEditor)
        view.dismissCommentEditor()
        XCTAssertEqual(page.annotations.count, 2)
    }
}
