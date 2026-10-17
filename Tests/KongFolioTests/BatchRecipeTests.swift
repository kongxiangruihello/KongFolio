import XCTest
import PDFKit
@testable import KongFolio

final class BatchRecipeTests: XCTestCase {
    /// `pages` pages of 200 x 300 with a black block in the middle.
    func book(pages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(box)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 40, y: 60, width: 120, height: 180))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-batch-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRecipesSurviveSavingAndLoading() throws {
        let defaults = try UserDefaults(suiteName: "kongfolio-test-" + UUID().uuidString).unwrap("无法创建设置")
        var recipe = WorkRecipe(name: "古籍")
        recipe.autoCrop = true
        recipe.ocr = OCRSettings()
        recipe.ocr?.vertical = true
        recipe.ocr?.ignoresTextLayer = true
        recipe.word = WordExportOptions()
        recipe.word?.imageSize = .small
        recipe.word?.replacements = [ReplacementRule(from: "爲", to: "為")]
        WorkRecipeStore.save([recipe], defaults)
        let loaded = WorkRecipeStore.load(defaults)
        XCTAssertEqual(loaded, [recipe])
        XCTAssertTrue(WorkRecipeStore.load(try UserDefaults(suiteName: "kongfolio-test-" + UUID().uuidString).unwrap("无法创建设置")).count == WorkRecipe.starters.count)
    }

    func testTheStepsOfARecipeAreDescribed() {
        XCTAssertTrue(WorkRecipe(name: "空", writePDF: false).isEmpty)
        let starter = WorkRecipe.starters[0]
        XCTAssertTrue(starter.summary.contains("自动裁边"))
        XCTAssertTrue(starter.summary.contains("竖排"))
        XCTAssertTrue(starter.summary.contains("Word"))
    }

    func testThePipelineCutsEveryPageAndKeepsThePageCount() throws {
        var recipe = WorkRecipe(name: "裁边")
        recipe.autoCrop = true
        let result = try BatchPipeline.process(book(pages: 4), recipe: recipe, replacements: [], wordURL: nil)
        XCTAssertEqual(result.pages, 4)
        let document = try PDFDocument(data: result.pdf.unwrap("没有输出")).unwrap("无法读取输出")
        XCTAssertEqual(document.pageCount, 4)
        for index in 0..<4 {
            let width = try document.page(at: index).unwrap("无页面").bounds(for: .cropBox).width
            XCTAssertEqual(min(Int(width), 170), Int(width))
        }
    }

    func testThePipelineWritesAWordFileWithoutOCR() throws {
        var recipe = WorkRecipe(name: "Word")
        recipe.word = WordExportOptions()
        recipe.word?.content = .imagesOnly
        recipe.writePDF = false
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.docx")
        let result = try BatchPipeline.process(book(pages: 2), recipe: recipe, replacements: [], wordURL: url)
        XCTAssertTrue(result.pdf == nil)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(Array(bytes.prefix(2)), [0x50, 0x4B])
    }

    func testAnUnreadableFileIsReportedNotCrashed() {
        var threw = false
        do { _ = try BatchPipeline.process(Data("not a pdf".utf8), recipe: WorkRecipe(name: "x"), replacements: [], wordURL: nil) } catch { threw = true }
        XCTAssertTrue(threw)
    }

    @MainActor func testTheQueueProcessesAFolderSkipsFinishedFilesAndRefusesTheSameFolder() async throws {
        let input = folder(), output = folder()
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try book(pages: 2).write(to: input.appendingPathComponent("b.pdf"))
        try book(pages: 3).write(to: input.appendingPathComponent("a.pdf"))
        try Data("broken".utf8).write(to: input.appendingPathComponent("c.pdf"))
        try Data("x".utf8).write(to: input.appendingPathComponent("notes.txt"))
        var recipe = WorkRecipe(name: "裁边")
        recipe.autoCrop = true

        let queue = BatchQueue()
        queue.load(input)
        XCTAssertEqual(queue.items.map { $0.url.lastPathComponent }, ["a.pdf", "b.pdf", "c.pdf"])

        queue.start(recipe: recipe, output: input, replacements: [])
        XCTAssertFalse(queue.running)
        XCTAssertTrue(queue.summary.contains("相同"))

        queue.start(recipe: recipe, output: output, replacements: [])
        while queue.running { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(try PDFDocument(url: output.appendingPathComponent("a.pdf")).unwrap("缺少 a").pageCount, 3)
        XCTAssertEqual(try PDFDocument(url: output.appendingPathComponent("b.pdf")).unwrap("缺少 b").pageCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("c.pdf").path))
        XCTAssertTrue(queue.summary.contains("处理 2 个"))
        XCTAssertTrue(queue.summary.contains("失败 1 个"))
        if case .failed = queue.items[2].state {} else { XCTAssertTrue(false) }
        // No partial files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers.count, 0)

        queue.start(recipe: recipe, output: output, replacements: [])
        while queue.running { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(queue.summary.contains("跳过 2 个"))
    }
}
