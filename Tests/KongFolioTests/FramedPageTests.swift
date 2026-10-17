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
