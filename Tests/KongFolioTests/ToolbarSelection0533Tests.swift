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

    func testDraggedToolbarOrderPersistsAcrossWindowWidths() throws {
        var profile = ReaderToolbarProfile()
        let pinned = profile.pinned
        XCTAssertTrue(profile.move(.ocr, relativeTo: .pageThumbnails, after: false))
        XCTAssertEqual(profile.visible(width: 320), [.ocr, .pageThumbnails, .search])
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
