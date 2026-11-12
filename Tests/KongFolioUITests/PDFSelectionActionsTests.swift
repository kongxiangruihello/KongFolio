import SwiftUI
import XCTest
@testable import KongFolio

final class PDFSelectionActionsTests: XCTestCase {
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
