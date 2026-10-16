import XCTest
import PDFKit
@testable import KongFolio

final class DataSafetyTests: XCTestCase {
    /// A workspace whose document can no longer be serialized (no pages, no cached bytes).
    @MainActor func brokenWorkspace() throws -> Workspace {
        let w = Workspace(); w.document = DocumentServicesTests().fixture()
        w.pushUndo(.snapshot(try w.snapshot()))
        w.document = PDFDocument(); w.edited()
        return w
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Undo used to drop the redo step silently when the current state could not be serialized.
    @MainActor func testUndoIsRefusedWhenCurrentStateCannotBeSerialized() throws {
        let w = try brokenWorkspace()
        XCTAssertEqual(w.history.count, 1)
        w.undo()
        XCTAssertEqual(w.history.count, 1)
        XCTAssertEqual(w.future.count, 0)
        XCTAssertNotNil(w.error)
    }

    @MainActor func testRedoIsRefusedWhenCurrentStateCannotBeSerialized() throws {
        let w = try brokenWorkspace()
        w.future.append(w.history.removeLast())
        w.redo()
        XCTAssertEqual(w.future.count, 1)
        XCTAssertEqual(w.history.count, 0)
        XCTAssertNotNil(w.error)
    }

    @MainActor func testFailedCheckpointClearsHistoryAndReports() throws {
        let w = try brokenWorkspace()
        w.checkpoint()
        XCTAssertEqual(w.history.count, 0)
        XCTAssertEqual(w.future.count, 0)
        XCTAssertNotNil(w.error)
    }

    @MainActor func testUndoStillWorksNormally() throws {
        let w = Workspace(); w.document = DocumentServicesTests().fixture()
        w.checkpoint()
        w.document.removePage(at: 2); w.edited()
        XCTAssertEqual(w.count, 2)
        w.undo(); XCTAssertEqual(w.count, 3); XCTAssertNil(w.error)
        w.redo()
        XCTAssertEqual(w.history.count, 1)
        XCTAssertEqual(w.future.count, 0)
    }

    // Saving over a project keeps the previous version; a damaged file never replaces a good backup.
    @MainActor func testSaveKeepsPreviousVersion() throws {
        let directory = try folder(), backups = directory.appendingPathComponent("Backups")
        defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(); w.document = DocumentServicesTests().fixture()
        let url = directory.appendingPathComponent("book.kongfolio")
        var archive = try w.snapshot(); archive.title = "第一版"
        XCTAssertNil(ProjectBackup.preserve(url, in: backups))   // nothing to keep yet
        try archive.write(url)
        archive.title = "第二版"
        XCTAssertNil(ProjectBackup.preserve(url, in: backups))
        try archive.write(url)
        let backup = ProjectBackup.location(for: url, in: backups)
        XCTAssertEqual(try ProjectArchive.read(backup).title, "第一版")
        XCTAssertEqual(try ProjectArchive.read(url).title, "第二版")
        // Only one previous version is kept.
        archive.title = "第三版"
        XCTAssertNil(ProjectBackup.preserve(url, in: backups))
        try archive.write(url)
        XCTAssertEqual(try ProjectArchive.read(backup).title, "第二版")
        // A damaged project file must not overwrite the good backup.
        try Data("damaged".utf8).write(to: url)
        XCTAssertNil(ProjectBackup.preserve(url, in: backups))
        XCTAssertEqual(try ProjectArchive.read(backup).title, "第二版")
    }

    func testBackupFailureIsReportedNotThrown() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let w = DocumentServicesTests().fixture()
        let url = directory.appendingPathComponent("a.kongfolio")
        try ProjectContainer.encode(ProjectArchive(pdf: w.dataRepresentation()!, title: "t", selection: 0, selectedPages: [0], mode: .document, recipes: [:], drafts: [:], dirty: false, projectPath: nil)).write(to: url)
        // The backup folder path is occupied by a regular file, so it cannot be created.
        let blocked = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)
        XCTAssertNotNil(ProjectBackup.preserve(url, in: blocked))
        XCTAssertEqual(Workspace.savedStatus(nil), "项目已保存")
        XCTAssertTrue(Workspace.savedStatus(FolioError(message: "磁盘已满")).contains("磁盘已满"))
    }
}

final class RecoveryCostTests: XCTestCase {
    // An unchanged document needs no recovery copy; an older copy is removed so it cannot be restored over the file.
    @MainActor func testCleanDocumentDropsRecoveryCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(storage: directory); w.bootstrap()
        w.document = DocumentServicesTests().fixture()
        XCTAssertTrue(w.flushRecovery())
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.recoveryURL.path))
        w.dirty = false
        w.scheduleRecovery()
        RecoveryWriter.shared.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.recoveryURL.path))
        XCTAssertEqual(w.recoveryStatus, "")
    }

    @MainActor func testTabsShareOneRecoveryQueue() throws {
        XCTAssertTrue(RecoveryWriter.shared === RecoveryWriter.shared)
    }
}
