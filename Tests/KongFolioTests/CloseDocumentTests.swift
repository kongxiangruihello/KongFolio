import XCTest
import PDFKit
@testable import KongFolio

final class CloseDocumentTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func pdfFile(in directory: URL, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        return url
    }

    @MainActor func testCloseReturnsToEmptyState() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(storage: directory); w.document = DocumentServicesTests().fixture()
        w.title = "书"; w.search = "x"; w.selection = 2; w.mode = .image
        w.history = [.snapshot(try w.snapshot())]
        XCTAssertTrue(w.closeDocument())
        XCTAssertEqual(w.count, 0); XCTAssertEqual(w.title, "未命名文档"); XCTAssertEqual(w.selection, 0)
        XCTAssertEqual(w.mode, .document); XCTAssertEqual(w.search, "")
        XCTAssertFalse(w.canUndo); XCTAssertFalse(w.canRedo); XCTAssertFalse(w.dirty)
        XCTAssertNil(w.projectURL); XCTAssertNil(w.page)
        XCTAssertTrue(w.status.contains("书"))
    }

    // The closed document must not come back from the autosave copy on the next launch.
    @MainActor func testCloseRemovesRecoveryCopy() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(storage: directory); w.document = DocumentServicesTests().fixture()
        XCTAssertTrue(w.flushRecovery())
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.recoveryURL.path))
        XCTAssertTrue(w.closeDocument())
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.recoveryURL.path))
    }

    @MainActor func testCloseIsRefusedWhileBusyOrWithNothingOpen() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(storage: directory)
        XCTAssertFalse(w.closeDocument())
        w.document = DocumentServicesTests().fixture(); w.busy = true
        XCTAssertFalse(w.closeDocument())
        XCTAssertEqual(w.count, 3)
    }

    // A freshly opened file is not unsaved work, so closing it does not ask anything.
    @MainActor func testFreshlyOpenedFileIsNotDirtyAndClosesWithoutAsking() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try pdfFile(in: directory, "a.pdf")
        let w = Workspace(storage: directory)
        w.load([url], prepared: try ImportServices.read([url]))
        XCTAssertNil(w.error)
        XCTAssertEqual(w.count, 3)
        XCTAssertFalse(w.dirty)
        XCTAssertTrue(w.closeDocument())
        XCTAssertEqual(w.count, 0)
    }

    // A merged document exists nowhere on disk, so it still counts as unsaved.
    @MainActor func testMergedDocumentStaysDirty() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try pdfFile(in: directory, "a.pdf"), second = try pdfFile(in: directory, "b.pdf")
        let w = Workspace(storage: directory)
        w.load([first, second], prepared: try ImportServices.read([first, second]))
        XCTAssertEqual(w.count, 6)
        XCTAssertTrue(w.dirty)
    }
}
