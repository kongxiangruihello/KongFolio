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
