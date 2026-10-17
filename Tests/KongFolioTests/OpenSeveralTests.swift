import XCTest
import PDFKit
@testable import KongFolio

final class OpenSeveralTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func pdf(in directory: URL, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        return url
    }

    // Several files are opened, not merged: one tab each, showing the file name at once.
    @MainActor func testSeveralFilesOpenInTheirOwnTabs() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [try pdf(in: directory, "甲.pdf"), try pdf(in: directory, "乙.pdf"), try pdf(in: directory, "丙.pdf")]
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        store.openEach(urls)
        let tabs = store.tabs.compactMap(\.workspace)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.map(\.displayName), ["甲.pdf", "乙.pdf", "丙.pdf"])
        XCTAssertEqual(store.selectedID, tabs[0].id)
        XCTAssertEqual(Set(tabs.map(\.slot)).count, 3)
    }

    @MainActor func testOpenSelectedUsesTabsUnlessMerging() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [try pdf(in: directory, "a.pdf"), try pdf(in: directory, "b.pdf")]
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let workspace = try store.activeWorkspace.unwrap("没有标签页")
        workspace.openSelected(urls, insert: false)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertFalse(workspace.showImportOrder)
        // An explicit merge still asks for the order and does not open tabs.
        let other = try folder(); defer { try? FileManager.default.removeItem(at: other) }
        let merging = WorkspaceStore(storage: other); merging.bootstrap()
        let target = try merging.activeWorkspace.unwrap("没有标签页")
        target.openSelected(urls, insert: false, merge: true)
        XCTAssertTrue(target.showImportOrder)
        XCTAssertEqual(target.pendingImports.count, 2)
        XCTAssertEqual(merging.tabs.count, 1)
    }

    // Without a tab store (older code paths, tests) several files are still merged after confirming the order.
    @MainActor func testWithoutStoreSeveralFilesAskForMergeOrder() throws {
        let w = Workspace()
        w.openSelected([URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")], insert: false)
        XCTAssertTrue(w.showImportOrder)
    }

    @MainActor func testDisplayNameAndSourceSurviveRestore() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(storage: directory); w.document = DocumentServicesTests().fixture(); w.title = "标题"
        XCTAssertEqual(w.displayName, "标题")
        w.sourceURL = URL(fileURLWithPath: "/tmp/书籍/论语.pdf")
        XCTAssertEqual(w.displayName, "论语.pdf"); XCTAssertEqual(w.displayPath, "/tmp/书籍/论语.pdf")
        w.projectURL = URL(fileURLWithPath: "/tmp/工作/笔记.kongfolio")
        XCTAssertEqual(w.displayName, "笔记.kongfolio")
        w.projectURL = nil
        let archive = try w.snapshot()
        XCTAssertEqual(archive.sourcePath, "/tmp/书籍/论语.pdf")
        let restored = Workspace(storage: directory)
        try restored.restore(archive)
        XCTAssertEqual(restored.displayName, "论语.pdf")
        // Undo restores keep the current source.
        restored.sourceURL = URL(fileURLWithPath: "/tmp/其他.pdf")
        try restored.restore(archive, keepProjectURL: true)
        XCTAssertEqual(restored.displayName, "其他.pdf")
    }

    @MainActor func testClosingForgetsTheSourceFile() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let w = Workspace(storage: directory); w.document = DocumentServicesTests().fixture()
        w.sourceURL = URL(fileURLWithPath: "/tmp/a.pdf")
        XCTAssertTrue(w.closeDocument())
        XCTAssertNil(w.sourceURL)
    }

    func testLayoutKeysAreStable() {
        XCTAssertEqual(LayoutKeys.sidebar, "KongFolio.showSidebar")
        XCTAssertEqual(LayoutKeys.inspector, "KongFolio.showInspector")
    }
}
