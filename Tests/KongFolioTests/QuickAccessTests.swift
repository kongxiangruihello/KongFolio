import XCTest
import PDFKit
@testable import KongFolio

final class QuickAccessTests: XCTestCase {
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

    /// A loaded tab that came from `url`.
    @MainActor func loadedTab(_ store: WorkspaceStore, _ url: URL) -> Workspace {
        let workspace = store.addWorkspace()
        workspace.document = DocumentServicesTests().fixture()
        workspace.sourceURL = url
        return workspace
    }

    func source(_ url: URL, page: Int = 1) -> SourceRef {
        SourceRef(path: url.path, fileName: url.lastPathComponent, page: page, pageLabel: nil, rects: [CGRect(x: 10, y: 20, width: 50, height: 10)])
    }

    // MARK: Tab search

    func testSearchMatchesPartsOfNames() {
        let names = ["论语译注.pdf", "孟子正义.pdf", "Report 2024 final.pdf", "report-draft.pdf", "笔记 论语.md"]
        XCTAssertEqual(TabSearch.rank(names, query: "论语"), [0, 4])
        XCTAssertEqual(TabSearch.rank(names, query: "REPORT"), [2, 3])        // both start the name: the order is kept
        XCTAssertEqual(TabSearch.rank(names, query: "draft"), [3])
        XCTAssertEqual(TabSearch.rank(names, query: "report final"), [2])     // every word must match
        XCTAssertEqual(TabSearch.rank(names, query: "rpt"), [2, 3])           // letters in order, gaps allowed
        XCTAssertEqual(TabSearch.rank(names, query: "没有"), [])
        XCTAssertEqual(TabSearch.rank(names, query: "  "), [0, 1, 2, 3, 4])
    }

    func testAWordStartingTheNameBeatsAMatchInTheMiddle() {
        let names = ["my-notes.pdf", "notes.pdf", "denotes.pdf"]
        XCTAssertEqual(TabSearch.rank(names, query: "notes"), [1, 0, 2])
    }

    // MARK: The switcher lists tabs

    @MainActor func testSwitcherListsRecentlyUsedTabsFirstAndFiltersByName() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let a = loadedTab(store, try pdf(in: directory, "甲.pdf"))
        let b = loadedTab(store, try pdf(in: directory, "乙.pdf"))
        let c = loadedTab(store, try pdf(in: directory, "丙.pdf"))
        store.select(a.id); store.select(c.id); store.select(b.id)       // b is the most recent, then c, then a
        let titles = store.switcherResults(for: "").map(\.switcherTitle)
        XCTAssertEqual(Array(titles.prefix(3)), ["乙.pdf", "丙.pdf", "甲.pdf"])
        XCTAssertEqual(store.switcherResults(for: "丙").map(\.id), [c.id])
        XCTAssertTrue(store.switcherResults(for: "不存在").isEmpty)
    }

    // MARK: Clicking a card

    @MainActor func testCardOpensItsSourceBesideTheDocumentInFront() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let urlA = try pdf(in: directory, "a.pdf"), urlB = try pdf(in: directory, "b.pdf")
        let a = loadedTab(store, urlA), b = loadedTab(store, urlB)
        store.select(a.id)
        XCTAssertTrue(store.reveal(source(urlB), beside: true))
        XCTAssertEqual(store.selectedID, a.id)                  // the document in front stays in front
        XCTAssertEqual(a.splitPartner?.id, b.id)                // and the source is on its right
        XCTAssertEqual(store.commandWorkspace?.id, b.id)        // where the reader is working now
    }

    @MainActor func testCardOpensItsSourceInTheTabWhenBesideIsOff() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let urlA = try pdf(in: directory, "a.pdf"), urlB = try pdf(in: directory, "b.pdf")
        let a = loadedTab(store, urlA), b = loadedTab(store, urlB)
        store.select(a.id)
        XCTAssertTrue(store.reveal(source(urlB), beside: false))
        XCTAssertEqual(store.selectedID, b.id)
        XCTAssertNil(a.splitPartner)
    }

    @MainActor func testCardFromTheDocumentInFrontJustGoesThere() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let urlA = try pdf(in: directory, "a.pdf")
        let a = loadedTab(store, urlA)
        store.select(a.id)
        XCTAssertTrue(store.reveal(source(urlA, page: 2), beside: true))
        XCTAssertNil(a.splitPartner)
        XCTAssertEqual(store.selectedID, a.id)
    }

    @MainActor func testCardWhoseFileIsNotOpenOpensInTheBackgroundBeside() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let urlA = try pdf(in: directory, "a.pdf"), urlC = try pdf(in: directory, "c.pdf")
        let a = loadedTab(store, urlA)
        store.select(a.id)
        let before = store.tabs.count
        XCTAssertTrue(store.reveal(source(urlC), beside: true))
        XCTAssertEqual(store.tabs.count, before + 1)
        XCTAssertEqual(store.selectedID, a.id)
        XCTAssertEqual(a.splitPartner?.sourceURL?.standardizedFileURL.path, urlC.standardizedFileURL.path)
    }

    @MainActor func testMissingSourceFileIsReportedNotOpened() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let a = loadedTab(store, try pdf(in: directory, "a.pdf"))
        store.select(a.id)
        XCTAssertFalse(store.reveal(source(directory.appendingPathComponent("没有.pdf")), beside: true))
        XCTAssertNil(a.splitPartner)
    }
}
