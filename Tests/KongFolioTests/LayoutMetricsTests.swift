import XCTest
@testable import KongFolio

final class LayoutMetricsTests: XCTestCase {
    func testTopBarStyleFollowsTheWidth() {
        XCTAssertEqual(LayoutMetrics.topBarStyle(width: 1600), .full)
        XCTAssertEqual(LayoutMetrics.topBarStyle(width: LayoutMetrics.fullTopBar), .full)
        XCTAssertEqual(LayoutMetrics.topBarStyle(width: LayoutMetrics.fullTopBar - 1), .icons)
        XCTAssertEqual(LayoutMetrics.topBarStyle(width: LayoutMetrics.iconTopBar), .icons)
        XCTAssertEqual(LayoutMetrics.topBarStyle(width: LayoutMetrics.iconTopBar - 1), .minimal)
        XCTAssertEqual(LayoutMetrics.topBarStyle(width: 380), .minimal)
    }

    // A panel the user switched on is hidden only while the window is too narrow for it.
    func testPanelsReturnWhenTheWindowIsWideEnough() {
        XCTAssertTrue(LayoutMetrics.showsSidebar(preferred: true, width: 1000))
        XCTAssertFalse(LayoutMetrics.showsSidebar(preferred: true, width: LayoutMetrics.sidebarMinimum - 1))
        XCTAssertTrue(LayoutMetrics.showsSidebar(preferred: true, width: LayoutMetrics.sidebarMinimum))
        XCTAssertFalse(LayoutMetrics.showsSidebar(preferred: false, width: 2000))
        XCTAssertFalse(LayoutMetrics.showsInspector(preferred: true, width: LayoutMetrics.inspectorMinimum - 1))
        XCTAssertTrue(LayoutMetrics.showsInspector(preferred: true, width: LayoutMetrics.inspectorMinimum))
        XCTAssertFalse(LayoutMetrics.showsInspector(preferred: false, width: 2000))
        XCTAssertFalse(LayoutMetrics.showsPreview(preferred: true, width: 300))
        XCTAssertTrue(LayoutMetrics.showsPreview(preferred: true, width: 900))
    }

    // The widest layout a window can need must fit inside the width at which its panels are shown.
    func testPanelsLeaveRoomForTheCanvas() {
        let canvasMinimum: CGFloat = 240, sidebarMinimum: CGFloat = 140, inspectorMinimum: CGFloat = 220
        XCTAssertTrue(LayoutMetrics.sidebarMinimum >= sidebarMinimum + canvasMinimum)
        XCTAssertTrue(LayoutMetrics.inspectorMinimum >= sidebarMinimum + canvasMinimum + inspectorMinimum)
    }
}
