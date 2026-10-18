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

final class PageRangeTests: XCTestCase {
    func testRangesAreReadAsPeopleWriteThem() {
        XCTAssertEqual(PageSpan.parse("", pageCount: 5) ?? [], [0, 1, 2, 3, 4])
        XCTAssertEqual(PageSpan.parse("1-3, 5", pageCount: 10) ?? [], [0, 1, 2, 4])
        XCTAssertEqual(PageSpan.parse("8-", pageCount: 10) ?? [], [7, 8, 9])
        XCTAssertEqual(PageSpan.parse("-2", pageCount: 10) ?? [], [0, 1])
        XCTAssertEqual(PageSpan.parse("３，５－６", pageCount: 3) == nil, true)
        XCTAssertEqual(PageSpan.parse("2，4－5", pageCount: 10) ?? [], [1, 3, 4])
        XCTAssertEqual(PageSpan.parse("9-20", pageCount: 10) ?? [], [8, 9])
        XCTAssertEqual(PageSpan.parse("50", pageCount: 10) ?? [-1], [])
    }

    func testNonsenseIsRejected() {
        XCTAssertTrue(PageSpan.parse("abc", pageCount: 10) == nil)
        XCTAssertTrue(PageSpan.parse("5-2", pageCount: 10) == nil)
        XCTAssertTrue(PageSpan.parse("0", pageCount: 10) == nil)
        XCTAssertTrue(PageSpan.parse("1-2-3", pageCount: 10) == nil)
    }

    func testRecipesSavedByVersion013StillLoad() throws {
        let old = #"[{"id":"5B1F2A5E-0000-4000-8000-000000000001","name":"旧配方","autoCrop":true,"writePDF":true,"useReplacementRules":true}]"#
        let loaded = try JSONDecoder().decode([WorkRecipe].self, from: Data(old.utf8))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "旧配方")
        XCTAssertTrue(loaded[0].autoCrop)
        XCTAssertEqual(loaded[0].pageRange, "")
        XCTAssertFalse(loaded[0].splitChapters)
    }
}

final class BatchChapterTests: XCTestCase {
    func picture(pages: Int) throws -> (data: Data, document: PDFDocument) {
        let data = try ScaleTests().picturePDF(pages: pages)
        return (data, try PDFDocument(data: data).unwrap("无法读取"))
    }

    func testThePageRangeKeepsOnlyThosePagesAndTheOutlineFollows() throws {
        let book = try picture(pages: 10)
        ReadingServices.applyOutline([OutlineEntry(page: 0, label: "封面", depth: 0), OutlineEntry(page: 4, label: "第一卷", depth: 0), OutlineEntry(page: 8, label: "第二卷", depth: 0)], to: book.document)
        let data = try book.document.dataRepresentation().unwrap("无法序列化")
        var recipe = WorkRecipe(name: "章节")
        recipe.pageRange = "3-10"
        recipe.splitChapters = true
        let result = try BatchPipeline.process(data, recipe: recipe, replacements: [], wordURL: nil)
        XCTAssertEqual(result.pages, 8)
        XCTAssertEqual(try PDFDocument(data: result.pdf.unwrap("没有输出")).unwrap("无法读取").pageCount, 8)
        // 封面 (page 1) was left out, so the book starts with the front-matter part, then 第一卷 (new page 3) and 第二卷 (new page 7).
        XCTAssertEqual(result.chapters.count, 3)
        XCTAssertEqual(try PDFDocument(data: result.chapters[0].data).unwrap("无法读取").pageCount, 2)
        XCTAssertEqual(try PDFDocument(data: result.chapters[1].data).unwrap("无法读取").pageCount, 4)
        XCTAssertEqual(try PDFDocument(data: result.chapters[2].data).unwrap("无法读取").pageCount, 2)
        XCTAssertTrue(result.chapters[1].name.contains("第一卷"))
    }

    func testARangeOutsideTheFileIsAnError() throws {
        var recipe = WorkRecipe(name: "越界")
        recipe.pageRange = "50-60"
        var message = ""
        do { _ = try BatchPipeline.process(picture(pages: 3).data, recipe: recipe, replacements: [], wordURL: nil) } catch { message = error.localizedDescription }
        XCTAssertTrue(message.contains("超出"))
        recipe.pageRange = "x"
        do { _ = try BatchPipeline.process(picture(pages: 3).data, recipe: recipe, replacements: [], wordURL: nil) } catch { message = error.localizedDescription }
        XCTAssertTrue(message.contains("无法理解"))
    }

    @MainActor func testTheQueueWritesAChapterFolderAndSkipsItNextTime() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-ch-" + UUID().uuidString, isDirectory: true)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-ch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        let book = try picture(pages: 6)
        ReadingServices.applyOutline([OutlineEntry(page: 0, label: "卷一", depth: 0), OutlineEntry(page: 3, label: "卷二", depth: 0)], to: book.document)
        try book.document.dataRepresentation().unwrap("无法序列化").write(to: input.appendingPathComponent("书.pdf"))
        var recipe = WorkRecipe(name: "章节")
        recipe.splitChapters = true
        recipe.writePDF = false
        let queue = BatchQueue()
        queue.load(input)
        queue.start(recipe: recipe, output: output, replacements: [])
        while queue.running { try await Task.sleep(nanoseconds: 50_000_000) }
        let folder = output.appendingPathComponent("书-章节", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names[0].hasPrefix("01-卷一"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasPrefix(".") }.count, 0)
        queue.start(recipe: recipe, output: output, replacements: [])
        while queue.running { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(queue.summary.contains("跳过 1 个"))
    }
}
