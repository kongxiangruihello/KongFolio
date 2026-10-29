import XCTest
import PDFKit
@testable import KongFolio

final class LazyTabsTests: XCTestCase {
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

    /// A loaded, unchanged tab that came from `url`.
    @MainActor func loadedTab(_ store: WorkspaceStore, _ url: URL?) -> Workspace {
        let workspace = store.addWorkspace()
        workspace.document = DocumentServicesTests().fixture()
        workspace.sourceURL = url
        return workspace
    }

    // MARK: Session format

    func testSessionFormats() throws {
        let session = Session(entries: [SessionEntry(slot: "", kind: .recovery), SessionEntry(slot: "ab12", kind: .file, path: "/tmp/书.pdf", position: ViewPosition(selection: 4, x: 1, y: 2, scale: 1.5))], selected: "ab12")
        XCTAssertEqual(Session.decode(try JSONEncoder().encode(session)), session)
        // The first format was a plain list of recovery slots.
        let legacy = Session.decode(try JSONEncoder().encode(["", "ff00"]))
        XCTAssertEqual(legacy?.entries.map(\.slot), ["", "ff00"])
        XCTAssertEqual(legacy?.entries.map(\.kind), [.recovery, .recovery])
        XCTAssertNil(Session.decode(Data("not json".utf8)))
        XCTAssertEqual(ViewPosition(selection: 0, x: 3, y: 4, scale: nil).point, CGPoint(x: 3, y: 4))
        XCTAssertNil(ViewPosition(selection: 0, x: 3, y: nil, scale: nil).point)
    }

    // MARK: Unloading and loading

    @MainActor func testUnloadKeepsTheFileAndPosition() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try pdf(in: directory, "a.pdf")
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let tab = loadedTab(store, url)
        tab.selection = 2
        XCTAssertTrue(tab.canUnload)
        tab.unload()
        XCTAssertEqual(tab.count, 0); XCTAssertTrue(tab.needsLoad)
        XCTAssertEqual(tab.displayName, "a.pdf")
        XCTAssertEqual(tab.pendingView?.selection, 2)
    }

    @MainActor func testNothingIsLostByUnloading() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try pdf(in: directory, "a.pdf")
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let tab = loadedTab(store, url)
        tab.dirty = true
        XCTAssertFalse(tab.canUnload)
        tab.unload(); XCTAssertEqual(tab.count, 3)
        tab.dirty = false; tab.busy = true
        XCTAssertFalse(tab.canUnload)
        tab.busy = false
        tab.checkpoint()   // undo history
        tab.dirty = false
        XCTAssertTrue(tab.canUnload)
        let anonymous = loadedTab(store, nil)   // not from a file: nothing to reload it from
        XCTAssertFalse(anonymous.canUnload)
    }

    @MainActor func testWaitingTabLoadsAndRestoresThePosition() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try pdf(in: directory, "a.pdf")
        let workspace = Workspace(storage: directory)
        workspace.sourceURL = url; workspace.needsLoad = true
        workspace.pendingView = ViewPosition(selection: 2, x: 10, y: 20, scale: 1.5)
        workspace.ensureLoaded()
        XCTAssertFalse(workspace.needsLoad)
        for _ in 0..<500 where workspace.busy || workspace.count == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(workspace.error)
        XCTAssertEqual(workspace.count, 3)
        XCTAssertEqual(workspace.selection, 2)
        XCTAssertEqual(workspace.readingPoint, CGPoint(x: 10, y: 20))
        XCTAssertEqual(workspace.readingScale, 1.5)
        XCTAssertEqual(workspace.sourceURL, url)
        XCTAssertFalse(workspace.dirty)
        XCTAssertNil(workspace.pendingView)
    }

    @MainActor func testEnsureLoadedDoesNothingWithoutNeed() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.ensureLoaded()
        XCTAssertFalse(workspace.busy)
        workspace.sourceURL = URL(fileURLWithPath: "/tmp/x.pdf")
        workspace.ensureLoaded()
        XCTAssertFalse(workspace.busy)
    }

    // MARK: Memory limit

    @MainActor func testOldestUnchangedTabsAreReleased() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap(); store.maxLoadedTabs = 100
        let tabs = try (1...4).map { loadedTab(store, try pdf(in: directory, "\($0).pdf")) }
        for tab in tabs { store.select(tab.id) }   // visit in order: 1 is the least recently used, 4 the most
        XCTAssertEqual(tabs.map(\.count), [3, 3, 3, 3])
        store.maxLoadedTabs = 2
        store.select(tabs[3].id)
        XCTAssertEqual(tabs.map(\.count), [0, 0, 3, 3])
        XCTAssertEqual(tabs.map(\.needsLoad), [true, true, false, false])
        XCTAssertEqual(tabs.map(\.displayName), ["1.pdf", "2.pdf", "3.pdf", "4.pdf"])
    }

    @MainActor func testChangedTabsStayLoadedEvenOverTheLimit() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap(); store.maxLoadedTabs = 100
        let tabs = try (1...3).map { loadedTab(store, try pdf(in: directory, "\($0).pdf")) }
        for tab in tabs { store.select(tab.id) }
        tabs[1].dirty = true
        store.maxLoadedTabs = 1
        store.select(tabs[2].id)
        XCTAssertEqual(tabs[1].count, 3)   // unsaved changes: kept although over the limit
        XCTAssertEqual(tabs[0].count, 0)
        XCTAssertEqual(tabs[2].count, 3)
    }

    // MARK: Opening many files

    @MainActor func testOnlyTheFirstOfManyFilesIsReadAtOnce() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (1...30).map { try pdf(in: directory, "文件\($0).pdf") }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        store.openEach(urls)
        let tabs = store.tabs.compactMap(\.workspace)
        XCTAssertEqual(tabs.count, 30)
        XCTAssertFalse(tabs[0].needsLoad)
        XCTAssertTrue(tabs.dropFirst().allSatisfy { $0.needsLoad && $0.count == 0 })
        XCTAssertEqual(tabs[29].displayName, "文件30.pdf")
        XCTAssertEqual(store.selectedID, tabs[0].id)
    }

    @MainActor func testSelectingAWaitingTabStartsReadingIt() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (1...3).map { try pdf(in: directory, "\($0).pdf") }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        store.openEach(urls)
        let second = try store.tabs[1].workspace.unwrap("没有标签页")
        XCTAssertTrue(second.needsLoad)
        store.select(second.id)
        XCTAssertFalse(second.needsLoad)
        XCTAssertTrue(second.busy)
    }

    @MainActor func testClosingTheOnlyWaitingTabForgetsItsFile() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let tab = try store.activeWorkspace.unwrap("没有标签页")
        tab.sourceURL = URL(fileURLWithPath: "/tmp/x.pdf"); tab.needsLoad = true
        store.close(tab.id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNil(tab.sourceURL); XCTAssertFalse(tab.needsLoad)
    }

    @MainActor func testNextAndPreviousTabWrapAround() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        store.newNote(); store.newNote()
        let ids = store.tabs.map(\.id)
        store.select(ids[0])
        store.selectPrevious(); XCTAssertEqual(store.selectedID, ids[2])
        store.selectNext(); XCTAssertEqual(store.selectedID, ids[0])
        store.selectNext(); XCTAssertEqual(store.selectedID, ids[1])
    }

    // MARK: Session without copying documents

    @MainActor func testQuittingDoesNotCopyUnchangedFiles() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let tab = loadedTab(store, try pdf(in: directory, "a.pdf"))
        XCTAssertTrue(tab.flushRecovery())   // an old copy from earlier editing
        XCTAssertTrue(FileManager.default.fileExists(atPath: tab.recoveryURL.path))
        XCTAssertTrue(store.prepareToClose())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tab.recoveryURL.path))
    }

    @MainActor func testSessionRestoresFilesLazilyAndEditedTabsFromRecovery() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let first = try store.activeWorkspace.unwrap("没有标签页")
        first.document = DocumentServicesTests().fixture(); first.sourceURL = try pdf(in: directory, "一.pdf"); first.selection = 1
        let second = loadedTab(store, try pdf(in: directory, "二.pdf"))
        let edited = loadedTab(store, nil)   // not from a file, so it is kept as a recovery copy
        XCTAssertTrue(store.prepareToClose())
        store.select(second.id)
        store.saveSession()

        let restored = WorkspaceStore(storage: directory); restored.bootstrap()
        let tabs = restored.tabs.compactMap(\.workspace)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs[0].displayName, "一.pdf")
        XCTAssertEqual(tabs[0].count, 0); XCTAssertTrue(tabs[0].needsLoad)
        XCTAssertEqual(tabs[0].pendingView?.selection, 1)
        XCTAssertEqual(tabs[1].displayName, "二.pdf")
        XCTAssertEqual(restored.activeWorkspace?.slot, second.slot)
        XCTAssertFalse(tabs[1].needsLoad)   // the tab that was in front is read right away
        XCTAssertEqual(tabs[2].count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.recoveryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.recoveryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited.recoveryURL.path))
    }

    @MainActor func testMissingFilesAreSkippedOnRestore() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = Session(entries: [SessionEntry(slot: "x1", kind: .file, path: directory.appendingPathComponent("gone.pdf").path)])
        try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("Session.json"))
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNil(store.activeWorkspace?.displayPath)
    }
}
