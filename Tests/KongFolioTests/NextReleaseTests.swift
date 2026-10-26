import XCTest
import PDFKit
@testable import KongFolio

final class NextReleaseTests: XCTestCase {
    func testDuplexOrderHandlesOddAndEvenCounts() {
        XCTAssertEqual(PageOrganization.duplexOrder(count: 6), [0, 5, 1, 4, 2, 3])
        XCTAssertEqual(PageOrganization.duplexOrder(count: 5), [0, 4, 1, 3, 2])
        XCTAssertEqual(PageOrganization.duplexOrder(count: 0), [])
        for count in 1...100 {
            let order = PageOrganization.duplexOrder(count: count)
            XCTAssertEqual(order.count, count)
            XCTAssertEqual(Set(order), Set(0..<count))
        }
    }

    @MainActor func testSelectionAndReverseKeepMetadataAndUndo() throws {
        let w = Workspace()
        w.document = DocumentServicesTests().fixture()
        w.document.page(at: 0)!.rotation = 90
        w.updateMeta(0) { $0.ocrRegions = [RecognizedLine(text: "first", box: .zero)] }
        w.selectPages(.odd)
        XCTAssertEqual(w.selectedPages, [0, 2])
        w.reverseSelectedPages()
        XCTAssertEqual(w.document.page(at: 2)!.rotation, 90)
        XCTAssertEqual(w.meta(2).ocrRegions?.first?.text, "first")
        w.undo()
        XCTAssertEqual(w.document.page(at: 0)!.rotation, 90)
        XCTAssertEqual(w.meta(0).ocrRegions?.first?.text, "first")
        w.selectPages(.even)
        XCTAssertEqual(w.selectedPages, [1])
        w.selectPages(.inverted)
        XCTAssertEqual(w.selectedPages, [0, 2])
        w.busy = true
        w.selectPages(.all)
        w.reverseSelectedPages()
        XCTAssertEqual(w.selectedPages, [0, 2])
        XCTAssertEqual(w.document.page(at: 0)!.rotation, 90)
    }

    @MainActor func testTruncatedProjectCannotReplaceGoodBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.kongfolio")
        let folder = directory.appendingPathComponent("Backups")
        let w = Workspace(); w.document = DocumentServicesTests().fixture()
        try w.snapshot().write(source)
        XCTAssertNil(ProjectBackup.preserve(source, in: folder))
        let backup = ProjectBackup.location(for: source, in: folder)
        let good = try Data(contentsOf: backup)
        try ProjectContainer.magic.write(to: source)
        XCTAssertNil(ProjectBackup.preserve(source, in: folder))
        XCTAssertEqual(try Data(contentsOf: backup), good)
    }

    @MainActor func testOversizedBlobRangeThrowsInsteadOfCrashing() throws {
        let w = Workspace(); w.document = DocumentServicesTests().fixture()
        let manifest = ProjectContainer.Manifest(archive: try w.snapshot().separated().manifest,
            blobs: ["pdf": ProjectContainer.BlobRange(offset: Int.max, length: Int.max)])
        let json = try JSONEncoder().encode(manifest)
        var data = ProjectContainer.magic
        var length = UInt64(json.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        XCTAssertThrowsError(try ProjectContainer.decode(data))
    }

    @MainActor func testBusyEmptyTabCannotBeClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let loading = store.activeWorkspace!
        loading.busy = true
        store.addWorkspace()
        store.close(loading.id)
        XCTAssertTrue(store.tabs.contains { $0.id == loading.id })
    }
}
