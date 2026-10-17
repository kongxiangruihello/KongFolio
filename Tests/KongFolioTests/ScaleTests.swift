import XCTest
import PDFKit
@testable import KongFolio

/// A book of a few hundred pages must not make everyday steps slow. These are timings on synthetic scans
/// (a page-sized picture with a printed block), run on CI where the numbers show up in the failure summary.
final class ScaleTests: XCTestCase {
    /// `pages` pages of 600 x 900 points, each holding a grey-noise picture so that the file is not trivially small.
    func picturePDF(pages: Int) throws -> Data {
        let width = 600, height = 900
        let context = try CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue).unwrap("无法创建画布")
        let document = PDFDocument()
        for number in 0..<pages {
            context.setFillColor(gray: 0.96, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(gray: 0.1, alpha: 1)
            for row in 0..<30 { context.fill(CGRect(x: 90 + CGFloat((row * 7 + number) % 13), y: 100 + CGFloat(row) * 24, width: 380, height: 10)) }
            let image = try context.makeImage().unwrap("无法生成图像")
            document.insert(try PDFPage(image: NSImage(cgImage: image, size: CGSize(width: width, height: height))).unwrap("无法生成页面"), at: document.pageCount)
        }
        return try document.dataRepresentation().unwrap("无法序列化")
    }

    func milliseconds(_ work: () throws -> Void) rethrows -> Int {
        let start = Date()
        try work()
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    @MainActor func testEverydayStepsOnAThreeHundredPageBook() throws {
        var data = Data()
        let built = try milliseconds { data = try picturePDF(pages: 300) }
        var opened: PDFDocument?
        let open = milliseconds { opened = PDFDocument(data: data) }
        let document = try opened.unwrap("无法打开")
        XCTAssertEqual(document.pageCount, 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = document
        let serialize = try milliseconds { _ = try workspace.pdfData() }
        let subset = try milliseconds { _ = try DocumentServices.subset(document, indexes: Array(0..<10)).dataRepresentation().unwrap("失败") }
        workspace.cropOdd = CropMargins(left: 0.1, right: 0.1, top: 0.1, bottom: 0.1)
        workspace.cropScope = .all
        let crop = milliseconds { workspace.applyCrop() }
        let undo = milliseconds { workspace.undo() }
        var recipe = WorkRecipe(name: "裁边")
        recipe.autoCrop = true
        recipe.pageRange = "1-60"
        let pipeline = try milliseconds { _ = try BatchPipeline.process(data, recipe: recipe, replacements: [], wordURL: nil) }
        var word = WorkRecipe(name: "Word")
        word.word = WordExportOptions()
        word.word?.content = .imagesOnly
        word.writePDF = false
        word.pageRange = "1-60"
        let url = directory.appendingPathComponent("w.docx")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wordTime = try milliseconds { _ = try BatchPipeline.process(data, recipe: word, replacements: [], wordURL: url) }
        // Measured on CI (macOS 15 / 26, synthetic scans): serialise 110 ms, crop 300 pages 4 ms, undo 100 ms,
        // 60-page recipe 3.5-4.3 s, 60-page Word file 0.6-1.0 s. Budgets leave room for slower runners.
        XCTAssertEqual(min(serialize, 3000), serialize)
        XCTAssertEqual(min(subset, 1000), subset)
        XCTAssertEqual(min(crop, 3000), crop)
        XCTAssertEqual(min(undo, 3000), undo)
        XCTAssertEqual(min(pipeline, 25000), pipeline)
        XCTAssertEqual(min(wordTime, 8000), wordTime)
    }
}
