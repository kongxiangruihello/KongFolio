import PDFKit
import SwiftUI
import XCTest
@testable import KongFolio

final class PDFSelectionActionsTests: XCTestCase {
    @MainActor func testQuickExcerptShowsSelectedTextAndEachConsecutiveImage() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        let quote = "A passage to excerpt"
        workspace.document = try TextImport.render(quote,markdown:false)
        let page = try XCTUnwrap(workspace.document.page(at:0))
        let window = NSWindow(contentRect:CGRect(x:40,y:40,width:650,height:560),
                              styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = DrawingPDFView(frame:window.contentLayoutRect)
        window.contentView = view
        view.workspace = workspace
        workspace.pdfView = view
        view.document = workspace.document
        view.autoScales = true
        window.orderFront(nil)
        view.go(to:page)
        view.layoutDocumentView()

        workspace.showAnnotationBar = true
        store.closeRightReadingPanel()
        let selected = try XCTUnwrap(workspace.document.findString(quote,with:[]).first)
        view.setCurrentSelection(selected,animate:false)
        workspace.quickPDFExcerpt()
        let text = try XCTUnwrap(store.journal.record(store.readingRecordID))
        XCTAssertEqual(text.quote,quote)
        XCTAssertTrue(store.rightReadingPanelVisible)
        XCTAssertEqual(store.readingDeskSection,.excerpts)
        XCTAssertEqual(store.readingExcerptFeedback?.recordID,text.id)
        XCTAssertEqual(store.readingExcerptFeedback?.opensEditor,true)
        XCTAssertFalse(workspace.showAnnotationBar)

        workspace.quickPDFExcerpt()
        XCTAssertEqual(workspace.tool,.region)
        func mouse(_ kind: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let location = view.convert(view.convert(point,from:page),to:nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with:kind,location:location,modifierFlags:[],
                                                    timestamp:1,windowNumber:window.windowNumber,
                                                    context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        var imageIDs = Set<UUID>()
        let bounds = page.bounds(for:.cropBox)
        let horizontalPositions: [CGFloat] = [0.2,0.5]
        for x in horizontalPositions {
            let start = CGPoint(x:bounds.minX+bounds.width*x,y:bounds.midY)
            let end = CGPoint(x:start.x+80,y:start.y+80)
            view.mouseDown(with:try mouse(.leftMouseDown,at:start))
            view.mouseDragged(with:try mouse(.leftMouseDragged,at:end))
            view.mouseUp(with:try mouse(.leftMouseUp,at:end))
            let image = try XCTUnwrap(store.journal.record(store.readingRecordID))
            XCTAssertEqual(image.kind,.image)
            XCTAssertNotNil(image.imageAsset)
            XCTAssertTrue(imageIDs.insert(image.id).inserted)
            XCTAssertEqual(store.readingExcerptFeedback?.recordID,image.id)
            XCTAssertEqual(store.readingExcerptFeedback?.opensEditor,true)
            XCTAssertEqual(workspace.tool,.region)
        }
        workspace.quickPDFExcerpt()
        XCTAssertEqual(workspace.tool,.select)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor func testSelectionActionsFitRegularAndNarrowPDFPanes() throws {
        _ = NSApplication.shared
        for compact in [false,true] {
            for editable in [false,true] {
                let actions = PDFSelectionActions(editable:editable,compact:compact,excerpt:{},note:{},copy:{},mark:{_,_,_ in})
                let host = NSHostingView(rootView:actions)
                XCTAssertGreaterThan(host.fittingSize.height,40)
                XCTAssertLessThanOrEqual(host.fittingSize.width,compact ? 230 : 340)
            }
        }
    }
}
