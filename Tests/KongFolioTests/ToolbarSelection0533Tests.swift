import AppKit
import XCTest
@testable import KongFolio

final class ToolbarSelection0533Tests: XCTestCase {
    func testOnlyCheckedToolsAppearEvenWhenWindowIsWide() {
        var p=ReaderToolbarProfile();p.pinned=["search","annotate"]
        XCTAssertEqual(p.visible(width:2000),[.search,.annotate])
        XCTAssertTrue(p.hidden(width:2000).contains(.open))
        p.pinned=[];XCTAssertTrue(p.visible(width:2000).isEmpty)
    }
    func testLegacyCommentChoiceBecomesAnnotationWithoutDuplicateButton() {
        let p=ReaderToolbarProfile(order:["comment","annotate","open"],pinned:["comment"])
        XCTAssertEqual(p.visible(width:2000),[.annotate])
        XCTAssertFalse(p.actions.contains(.comment))
        XCTAssertEqual(p.actions.filter{$0 == .annotate}.count,1)
    }
    func testSlimDefaultsAndDocumentContext() {
        let profile = ReaderToolbarProfile()
        XCTAssertEqual(profile.visible(width:1280),[.navigation,.pageThumbnails,.ocr,.zoom,.search,.annotate,.excerpt,.note,.library])
        XCTAssertEqual(profile.visible(width:1280,context:.empty),[.newFile,.open,.sidebar])
        XCTAssertEqual(profile.visible(width:1280,context:.text),[.newFile,.open,.sidebar,.export])
    }

    func testOCRIsPinnedOnUpgradeAndCanBeUnpinned() throws {
        var previous = ReaderToolbarProfile()
        previous.order.removeAll { $0 == "ocr" }
        previous.pinned = ["pageThumbnails", "search", "annotate"]
        let encoder = JSONEncoder()
        var upgraded = ReaderToolbarProfile.decode(try encoder.encode(previous))
        XCTAssertEqual(upgraded.visible(width: 320), [.pageThumbnails, .ocr, .search])
        XCTAssertFalse(upgraded.visible(width: 1280, context: .text).contains(.ocr))
        upgraded.pin(.ocr, enabled: false, context: .pdf)
        XCTAssertFalse(ReaderToolbarProfile.decode(try encoder.encode(upgraded)).visible(width: 1280).contains(.ocr))
    }

    func testNarrowWindowPrioritizesSelectedReadingToolsAndRestoresCustomOrder() {
        let order = ["newFile","open","signature","library","sidebar","annotate","search"]
        let profile = ReaderToolbarProfile(order:order,pinned:Set(order))
        XCTAssertEqual(profile.visible(width:320),[.sidebar,.annotate,.search])
        XCTAssertEqual(profile.visible(width:1280).map(\.rawValue),order)
        XCTAssertEqual(profile.visible(width:1280,context:.text),[.newFile,.open,.library,.sidebar])
    }

    @MainActor
    func testToolbarNativeMouseEventsDistinguishClickFromDrop() throws {
        let frames: [FileToolbarAction: CGRect] = [
            .pageThumbnails: CGRect(x: 0, y: 0, width: 40, height: 32),
            .ocr: CGRect(x: 40, y: 0, width: 40, height: 32)
        ]
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 16),
                                            modifierFlags: [], timestamp: 1, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        var track = ReaderToolbarMouseTrack()
        let down = try mouse(.leftMouseDown, 20)
        let up = try mouse(.leftMouseUp, 21)
        guard case .consume = track.handle(down, at: down.locationInWindow, frames: frames) else {
            return XCTFail("The native menu must wait for a click or a drag")
        }
        guard case let .click(originalDown, originalUp) = track.handle(up, at: up.locationInWindow, frames: frames) else {
            return XCTFail("A click must replay the original events")
        }
        XCTAssertTrue(originalDown === down)
        XCTAssertTrue(originalUp === up)

        _ = track.handle(down, at: down.locationInWindow, frames: frames)
        let drag = try mouse(.leftMouseDragged, 65)
        let expected = ReaderToolDropPosition(action: .ocr, after: true)
        guard case let .preview(destination) = track.handle(drag, at: drag.locationInWindow, frames: frames) else {
            return XCTFail("Dragging from the menu icon must preview an insertion")
        }
        XCTAssertEqual(destination, expected)
        let drop = try mouse(.leftMouseUp, 66)
        guard case let .drop(source, position) = track.handle(drop, at: drop.locationInWindow, frames: frames) else {
            return XCTFail("A drop must reorder without replaying a click")
        }
        XCTAssertEqual(source, .pageThumbnails)
        XCTAssertEqual(position, expected)
        XCTAssertFalse(track.isPressed)

        _ = track.handle(down, at: down.locationInWindow, frames: frames)
        _ = track.handle(drag, at: drag.locationInWindow, frames: frames)
        let outside = try mouse(.leftMouseUp, 81)
        guard case .drop(_, nil) = track.handle(outside, at: outside.locationInWindow, frames: frames) else {
            return XCTFail("Dropping outside should leave the order alone")
        }
    }

    func testDraggedToolbarOrderPersistsAcrossWindowWidths() throws {
        var profile = ReaderToolbarProfile()
        let pinned = profile.pinned
        XCTAssertTrue(profile.move(.ocr, relativeTo: .pageThumbnails, after: false))
        XCTAssertEqual(profile.visible(width: 320), [.ocr, .pageThumbnails, .excerpt])
        XCTAssertFalse(profile.move(.ocr, relativeTo: .pageThumbnails, after: false))
        XCTAssertFalse(profile.move(.ocr, relativeTo: .ocr, after: true))
        XCTAssertTrue(profile.move(.ocr, relativeTo: .library, after: true))
        let restored = ReaderToolbarProfile.decode(try JSONEncoder().encode(profile))
        XCTAssertEqual(restored.visible(width: 1280).suffix(2), [.library, .ocr])
        XCTAssertEqual(restored.pinned, pinned)
        XCTAssertEqual(Set(restored.actions), Set(FileToolbarAction.allCases))
    }

    func testNarrowWindowsKeepSelectedOrderAndOverflowEveryOtherAction() {
        var p=ReaderToolbarProfile();p.pinned=["open","annotate","library","signature"]
        for width in stride(from:320.0,through:1800,by:20) {
            let visible=p.visible(width:width)
            XCTAssertTrue(visible.allSatisfy{p.pinned.contains($0.rawValue)})
            XCTAssertEqual(visible,p.actions.filter{visible.contains($0)})
            XCTAssertEqual(Set(visible+p.hidden(width:width)),Set(p.actions))
        }
    }
}
