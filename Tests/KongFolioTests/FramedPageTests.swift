import XCTest
@testable import KongFolio

/// Pages of old Chinese books are printed inside a frame (版框): rules along the top and bottom, a bar at the side.
/// Seen from above, a rule running across the whole page joins all columns into one.
final class FramedPageTests: XCTestCase {
    /// 400 x 600 page: four columns of ten 30 x 30 "characters"; optionally with the frame.
    func page(frame: Bool) -> VerticalText.Gray {
        let width = 400, height = 600
        var pixels = [UInt8](repeating: 240, count: width * height)
        func fill(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>) { for row in y { for column in x { pixels[row * width + column] = 20 } } }
        for column in 0..<4 {
            let x = 80 + column * 80
            for cell in 0..<10 { let y = 80 + cell * 40; fill(x...(x + 29), y...(y + 29)) }
        }
        if frame {
            fill(10...389, 40...47)           // top rule
            fill(10...389, 560...567)         // bottom rule
            fill(12...20, 40...567)           // dark bar at the side
        }
        return VerticalText.Gray(width: width, height: height, pixels: pixels)
    }

    func testTheColumnsAreFoundWithoutAFrame() {
        let columns = VerticalText.layout(page(frame: false))
        XCTAssertEqual(columns.count, 4)
        XCTAssertEqual(columns.map(\.cells.count), [10, 10, 10, 10])
        XCTAssertTrue(columns[0].x0 > columns[3].x0)            // right to left
    }

    func testRulesOfTheFrameDoNotJoinTheColumns() {
        let gray = page(frame: true)
        let level = VerticalText.threshold(gray)
        let cleared = VerticalText.clearingFrame(gray, level: level)
        XCTAssertEqual(cleared[200, 44], 255)                    // the top rule is gone
        XCTAssertEqual(cleared[16, 300], 255)                    // and so is the bar
        XCTAssertEqual(cleared[90, 90], 20)                      // the text is untouched
        let columns = VerticalText.layout(gray)
        XCTAssertEqual(columns.count, 4)
        XCTAssertEqual(columns.map(\.cells.count), [10, 10, 10, 10])
    }

    func testAPageWithoutRulesIsLeftAlone() {
        let gray = page(frame: false)
        XCTAssertEqual(VerticalText.clearingFrame(gray, level: VerticalText.threshold(gray)).pixels, gray.pixels)
    }

    func testAMostlyDarkPageIsNotWipedOut() {
        let dark = VerticalText.Gray(width: 100, height: 100, pixels: [UInt8](repeating: 10, count: 10_000))
        XCTAssertEqual(VerticalText.clearingFrame(dark, level: 128).pixels, dark.pixels)
    }

    func testOCRSettingsSavedBeforeStillLoadAndRememberTheNewOption() throws {
        let old = #"{"languages":["zh-Hant","en-US"],"dpi":400,"vertical":true,"minimumTextCharacters":20}"#
        let decoded = try JSONDecoder().decode(OCRSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.dpi, 400)
        XCTAssertTrue(decoded.vertical)
        XCTAssertFalse(decoded.ignoresTextLayer)
        var changed = decoded
        changed.ignoresTextLayer = true
        let again = try JSONDecoder().decode(OCRSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertTrue(again.ignoresTextLayer)
    }
}

/// What a real page needed beyond the simple cases (see RealPageTests): frames made of broken rules, columns that touch,
/// and fragments of the frame at the head of a column.
final class FramedPageDetailTests: XCTestCase {
    func blank(_ width: Int, _ height: Int) -> [UInt8] { [UInt8](repeating: 240, count: width * height) }

    func testABrokenRuleIsClearedByItsRunsAndASolidOneByItsRows() {
        let width = 600, height = 400
        var pixels = blank(width, height)
        // A rule made of three long pieces with small gaps between them.
        for row in 50...53 { for x in 20..<190 { pixels[row * width + x] = 20 }; for x in 195..<390 { pixels[row * width + x] = 20 }; for x in 395..<580 { pixels[row * width + x] = 20 } }
        // A character-sized block that must survive.
        for row in 150..<190 { for x in 100..<140 { pixels[row * width + x] = 20 } }
        let gray = VerticalText.Gray(width: width, height: height, pixels: pixels)
        let cleared = VerticalText.clearingLongRuns(gray, level: 128)
        XCTAssertEqual(cleared[100, 51], 255)
        XCTAssertEqual(cleared[300, 52], 255)
        XCTAssertEqual(cleared[120, 170], 20)
    }

    func testWideRunsAreCutWhereTheInkIsThinnest() {
        // Two columns of width 60 that touch with a thin bridge: one run of 130.
        var ink = [Int](repeating: 0, count: 200)
        for x in 20..<80 { ink[x] = 400 }
        for x in 80..<90 { ink[x] = 5 }
        for x in 90..<150 { ink[x] = 400 }
        let parts = VerticalText.splitWide(20...149, ink: ink, typical: 60)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].upperBound >= 79 && parts[0].upperBound <= 90)
        XCTAssertTrue(parts[1].lowerBound >= 80 && parts[1].lowerBound <= 91)
        XCTAssertEqual(VerticalText.splitWide(20...80, ink: ink, typical: 60).count, 1)          // an ordinary column is not cut
        XCTAssertTrue(VerticalText.splitWide(0...399, ink: [Int](repeating: 100, count: 400), typical: 60).isEmpty)      // a blob is dropped
    }

    func testFragmentsOfTheFrameAtTheHeadOfAColumnAreRemoved() {
        func column(_ x: Int, thinAt: Int?) -> VerticalText.Column {
            var cells: [ClosedRange<Int>] = []
            if let thinAt { cells.append(thinAt...(thinAt + 3)) }                  // a thin cell: 4 px tall in a 60 px column
            for index in 0..<10 { cells.append((200 + index * 70)...(200 + index * 70 + 55)) }
            return VerticalText.Column(x0: x, x1: x + 59, cells: cells)
        }
        // Rule pieces at the same height in many columns, and one alone far above its column's text.
        let columns = [column(500, thinAt: 100), column(400, thinAt: 102), column(300, thinAt: 99), column(200, thinAt: nil), column(100, thinAt: 40)]
        let cleaned = VerticalText.removingRuleFragments(columns)
        XCTAssertEqual(cleaned.map(\.cells.count), [10, 10, 10, 10, 10])
        // A real 一 right at the head of a column, close to the next character, stays.
        var real = column(100, thinAt: nil)
        real.cells.insert(190...193, at: 0)
        XCTAssertEqual(VerticalText.removingRuleFragments([real, column(200, thinAt: nil)]).first?.cells.count, 11)
    }
}
