import XCTest
import PDFKit
@testable import KongFolio

final class ChapterSplitTests: XCTestCase {
    func entry(_ page: Int, _ depth: Int, _ label: String) -> OutlineEntry { OutlineEntry(page: page, label: label, depth: depth, point: nil) }

    func testTopLevelPartsCoverEveryPage() {
        let entries = [entry(0, 0, "序"), entry(3, 0, "第一章"), entry(3, 1, "第一节"), entry(5, 1, "1.2"), entry(10, 0, "第二章")]
        let parts = ChapterSplit.parts(entries: entries, pageCount: 20, depth: 0)
        XCTAssertEqual(parts, [ChapterPart(title: "序", pages: 0..<3), ChapterPart(title: "第一章", pages: 3..<10), ChapterPart(title: "第二章", pages: 10..<20)])
    }

    func testDeeperLevelSplitsMoreAndKeepsFirstEntryOnSharedPage() {
        let entries = [entry(0, 0, "序"), entry(3, 0, "第一章"), entry(3, 1, "第一节"), entry(5, 1, "1.2"), entry(10, 0, "第二章")]
        let parts = ChapterSplit.parts(entries: entries, pageCount: 20, depth: 1)
        XCTAssertEqual(parts.map(\.title), ["序", "第一章", "1.2", "第二章"])
        XCTAssertEqual(parts.map(\.pages), [0..<3, 3..<5, 5..<10, 10..<20])
    }

    func testFrontMatterUnsortedAndOutOfRangeEntries() {
        let entries = [entry(8, 0, "后"), entry(2, 0, "前"), entry(99, 0, "越界"), entry(-1, 0, "负数")]
        let parts = ChapterSplit.parts(entries: entries, pageCount: 10, depth: 0)
        XCTAssertEqual(parts.map(\.title), [ChapterSplit.frontMatterTitle, "前", "后"])
        XCTAssertEqual(parts.map(\.pages), [0..<2, 2..<8, 8..<10])
        XCTAssertEqual(parts.reduce(0) { $0 + $1.pages.count }, 10)
        XCTAssertTrue(ChapterSplit.parts(entries: [], pageCount: 10, depth: 0).isEmpty)
        XCTAssertEqual(ChapterSplit.depths(entries + [entry(4, 2, "x")], pageCount: 10), [0, 2])
    }

    func testFileNamesAreOrderedAndSafe() {
        let name = ChapterSplit.fileName(index: 3, total: 12, title: "第1/2章: 绪论?\n")
        XCTAssertEqual(name, "03-第1_2章_ 绪论__.pdf")
        XCTAssertTrue(ChapterSplit.fileName(index: 7, total: 120, title: "x").hasPrefix("007-"))
        XCTAssertEqual(ChapterSplit.fileName(index: 1, total: 5, title: "  ... "), "01-章节.pdf")
        XCTAssertTrue(ChapterSplit.fileName(index: 1, total: 5, title: String(repeating: "长", count: 200)).count <= 3 + 60 + 4)
    }

    func testJobWritesOneFilePerChapter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DocumentServicesTests().fixture().dataRepresentation()!
        let parts = [ChapterPart(title: "甲", pages: 0..<1), ChapterPart(title: "乙", pages: 1..<3)]
        let spec = JobSpec(operation: .chapters, source: source, pages: [0, 1, 2], destination: directory, revision: UUID(), chapters: parts)
        let result = try BackgroundJobs.run(spec) { _ in }
        let folder = try result.destination.unwrap("没有输出目录")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["01-甲.pdf", "02-乙.pdf"])
        XCTAssertEqual(PDFDocument(url: folder.appendingPathComponent("01-甲.pdf"))?.pageCount, 1)
        XCTAssertEqual(PDFDocument(url: folder.appendingPathComponent("02-乙.pdf"))?.pageCount, 2)
        // No staging folder is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers.count, 0)
    }

    func testInvalidRangesAreRejected() throws {
        let source = DocumentServicesTests().fixture().dataRepresentation()!
        let spec = JobSpec(operation: .chapters, source: source, pages: [0, 1, 2], destination: FileManager.default.temporaryDirectory, revision: UUID(), chapters: [ChapterPart(title: "越界", pages: 1..<9)])
        XCTAssertThrowsError(try BackgroundJobs.run(spec) { _ in })
    }
}
