import XCTest
import PDFKit
@testable import KongFolio

final class SplitReadingTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor func tab(_ store: WorkspaceStore, _ name: String) -> Workspace {
        let workspace = store.addWorkspace()
        workspace.document = DocumentServicesTests().fixture()
        workspace.sourceURL = URL(fileURLWithPath: "/tmp/\(name).pdf")
        return workspace
    }

    @MainActor func testSplitShowsAnotherOpenDocumentBesideTheActiveOne() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let a = tab(store, "a"), b = tab(store, "b"), c = tab(store, "c")
        store.select(a.id)
        XCTAssertEqual(Set(store.splitCandidates.map(\.id)), [b.id, c.id])
        store.openSplit(with: b.id)
        XCTAssertEqual(a.splitPartner?.id, b.id)
        XCTAssertFalse(a.splitSync)
        store.closeSplit()
        XCTAssertNil(a.splitPartner)
    }

    @MainActor func testADocumentIsNeverSplitWithItself() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let a = tab(store, "a")
        store.select(a.id)
        store.openSplit(with: a.id)
        XCTAssertNil(a.splitPartner)
    }

    @MainActor func testClosingThePartnerEndsTheSplit() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let a = tab(store, "a"), b = tab(store, "b")
        store.select(a.id)
        store.openSplit(with: b.id)
        let before = store.tabs.count
        store.close(b.id)
        XCTAssertNil(a.splitPartner)
        XCTAssertEqual(store.tabs.count, before - 1)
    }

    @MainActor func testThePartnerIsNotUnloadedToSaveMemory() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url: (String) throws -> URL = { name in
            let file = directory.appendingPathComponent(name)
            try DocumentServicesTests().fixture().dataRepresentation()!.write(to: file)
            return file
        }
        let store = WorkspaceStore(storage: directory); store.bootstrap(); store.maxLoadedTabs = 100
        let a = tab(store, "a"), b = tab(store, "b"), c = tab(store, "c")
        a.sourceURL = try url("a.pdf"); b.sourceURL = try url("b.pdf"); c.sourceURL = try url("c.pdf")
        for workspace in [a, b, c] { store.select(workspace.id) }   // visit in order: a is the oldest, c the newest
        store.select(a.id)
        store.openSplit(with: b.id)
        XCTAssertEqual([a, b, c].map(\.count), [3, 3, 3])
        // b is the least recently used, but it is on screen beside a, so the other tab is the one to go.
        b.lastActive = Date(timeIntervalSince1970: 0)
        c.lastActive = Date()
        store.maxLoadedTabs = 2
        store.select(a.id)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(c.count, 0)
    }

    func testLayoutRulesForTheSplitPane() {
        XCTAssertFalse(LayoutMetrics.showsSplit(width: LayoutMetrics.splitMinimum - 1))
        XCTAssertTrue(LayoutMetrics.showsSplit(width: LayoutMetrics.splitMinimum))
        XCTAssertTrue(LayoutMetrics.showsInspector(preferred: true, width: 1000))
        XCTAssertFalse(LayoutMetrics.showsInspector(preferred: true, width: 1000, splitShown: true))
        XCTAssertTrue(LayoutMetrics.showsInspector(preferred: true, width: LayoutMetrics.inspectorWithSplitMinimum, splitShown: true))
    }
}
