import XCTest
@testable import KongFolio

final class RedMarksTests: XCTestCase {
    /// White page, a black square, and a dark-red "seal" square that half covers it.
    func page() throws -> CGImage {
        let width = 100, height = 100
        var data = [UInt8](repeating: 255, count: width * height * 4)
        func fill(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            for row in y { for column in x { let i = (row * width + column) * 4; data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255 } }
        }
        fill(10...39, 10...39, 0, 0, 0)                  // black ink
        fill(30...79, 30...79, 190, 40, 40)              // a dark red seal overlapping the corner of the ink
        fill(30...39, 30...39, 0, 0, 0)                  // where the ink was on top of the seal
        return try data.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }.unwrap("无法生成测试图")
    }

    func testRedIsOnlyRed() {
        XCTAssertTrue(DocumentServices.isRed(r: 190, g: 40, b: 40))
        XCTAssertTrue(DocumentServices.isRed(r: 220, g: 90, b: 80))
        XCTAssertFalse(DocumentServices.isRed(r: 0, g: 0, b: 0))
        XCTAssertFalse(DocumentServices.isRed(r: 120, g: 120, b: 120))
        XCTAssertFalse(DocumentServices.isRed(r: 235, g: 215, b: 170))        // yellowed paper
        XCTAssertFalse(DocumentServices.isRed(r: 243, g: 224, b: 222))        // the faint seal of a real page
    }

    func testASealBecomesPaperAndInkStaysInk() throws {
        let plain = try VerticalText.Gray(page())
        let cleaned = try VerticalText.Gray(DocumentServices.withoutRedMarks(page()))
        XCTAssertEqual(cleaned.width, 100)
        XCTAssertTrue(plain[60, 60] < 120)                    // as plain grey the seal looks like ink
        XCTAssertEqual(cleaned[60, 60], 255)                  // without red it is paper
        XCTAssertEqual(cleaned[20, 20], 0)                    // ink is ink
        XCTAssertEqual(cleaned[34, 34], 0)                    // ink on top of the seal is still ink
        XCTAssertEqual(cleaned[90, 90], 255)
    }

    func testTheOptionIsOnByDefaultAndSavedSettingsStillLoad() throws {
        XCTAssertTrue(OCRSettings().ignoresRedMarks)
        let old = #"{"languages":["zh-Hant"],"dpi":300,"vertical":true,"minimumTextCharacters":20}"#
        XCTAssertTrue(try JSONDecoder().decode(OCRSettings.self, from: Data(old.utf8)).ignoresRedMarks)
        var settings = OCRSettings()
        settings.ignoresRedMarks = false
        let again = try JSONDecoder().decode(OCRSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(again.ignoresRedMarks)
    }
}
