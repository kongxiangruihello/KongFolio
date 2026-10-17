import XCTest
import PDFKit
@testable import KongFolio

final class ExcerptPolishTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A store whose first tab holds a text document, and a selection of its first words.
    @MainActor func makeStore(_ directory: URL, text: String = "学而时习之，不亦说乎？\n有朋自远方来，不亦乐乎？") throws -> (store: WorkspaceStore, tab: Workspace, selection: PDFSelection) {
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let tab = try store.activeWorkspace.unwrap("没有标签页")
        tab.document = try TextImport.render(text, markdown: false)
        let match = try tab.document.findString("学而时习之", withOptions: []).first.unwrap("没有找到文字")
        return (store, tab, match)
    }

    @MainActor func highlights(_ tab: Workspace) -> [PDFAnnotation] {
        (0..<tab.count).flatMap { tab.document.page(at: $0)?.annotations ?? [] }.filter { $0.type == "Highlight" }
    }

    func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: LayoutKeys.tintSources)
        UserDefaults.standard.removeObject(forKey: LayoutKeys.board)
    }

    // MARK: Colouring the source

    @MainActor func testExcerptColoursTheSourceAndCanBeUndone() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, tab, selection) = try makeStore(directory); defer { store.board.removeBackup() }
        tab.excerpt(selection: selection)
        let card = try store.board.cards.first.unwrap("没有卡片")
        let marks = highlights(tab)
        XCTAssertFalse(marks.isEmpty)
        XCTAssertTrue(marks.allSatisfy { tab.cardID(of: $0) == card.id })
        XCTAssertTrue(tab.dirty)
        XCTAssertEqual(store.board.focusedID, card.id)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: LayoutKeys.board), true)
        tab.undo()
        XCTAssertTrue(highlights(tab).isEmpty)
        tab.redo()
        XCTAssertFalse(highlights(tab).isEmpty)
    }

    @MainActor func testSelectingTheSameWordsTwiceDoesNotDuplicate() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, tab, selection) = try makeStore(directory); defer { store.board.removeBackup() }
        tab.excerpt(selection: selection)
        let before = highlights(tab).count
        tab.excerpt(selection: selection)
        XCTAssertEqual(store.board.cards.count, 1)
        XCTAssertEqual(highlights(tab).count, before)
        XCTAssertTrue(tab.status.contains("已经在工作区"))
    }

    @MainActor func testColouringCanBeSwitchedOff() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, tab, selection) = try makeStore(directory); defer { store.board.removeBackup() }
        Workspace.tintsSources = false
        tab.excerpt(selection: selection)
        XCTAssertEqual(store.board.cards.count, 1)
        XCTAssertTrue(highlights(tab).isEmpty)
        XCTAssertFalse(tab.dirty)
    }

    @MainActor func testDeletingTheCardTakesTheColourOffAndRecolouringFollows() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, tab, selection) = try makeStore(directory); defer { store.board.removeBackup() }
        tab.excerpt(selection: selection)
        let id = try store.board.cards.first.unwrap("没有卡片").id
        let yellow = try highlights(tab).first.unwrap("没有高亮").color.usingColorSpace(.deviceRGB).unwrap("颜色")
        store.board.setColor(id, .blue)
        let blue = try highlights(tab).first.unwrap("没有高亮").color.usingColorSpace(.deviceRGB).unwrap("颜色")
        XCTAssertTrue(blue.blueComponent > yellow.blueComponent)
        store.board.remove(id)
        XCTAssertTrue(highlights(tab).isEmpty)
        XCTAssertTrue(store.board.cards.isEmpty)
        tab.undo()
        XCTAssertFalse(highlights(tab).isEmpty)   // the colour comes back with undo
    }

    @MainActor func testRegionExcerptIsColouredToo() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, tab, _) = try makeStore(directory); defer { store.board.removeBackup() }
        let page = try tab.document.page(at: 0).unwrap("没有页面")
        tab.excerptRegion(imageData: Data([1, 2, 3]), size: CGSize(width: 100, height: 60), page: page, pageRect: CGRect(x: 80, y: 600, width: 100, height: 60))
        let card = try store.board.cards.first.unwrap("没有卡片")
        XCTAssertEqual(card.kind, .image)
        XCTAssertEqual(highlights(tab).count, 1)
        XCTAssertEqual(tab.cardID(of: highlights(tab)[0]), card.id)
    }

    // MARK: From the document back to the card

    @MainActor func testClickingTheColourShowsTheCard() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, tab, selection) = try makeStore(directory); defer { store.board.removeBackup() }
        tab.excerpt(selection: selection)
        let id = try store.board.cards.first.unwrap("没有卡片").id
        store.board.focusedID = nil
        UserDefaults.standard.set(false, forKey: LayoutKeys.board)
        tab.focusCard(id)
        XCTAssertEqual(store.board.focusedID, id)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: LayoutKeys.board))
        store.board.focusedID = nil
        tab.focusCard(UUID())   // not a card of this workspace
        XCTAssertNil(store.board.focusedID)
    }

    // MARK: From the card back to the document

    @MainActor func testExcerptIsFoundAgainWhenPagesHaveMoved() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let text = (1...400).map { "第\($0)行：用于检验摘录定位的一行文字。" }.joined(separator: "\n")
        let (store, tab, _) = try makeStore(directory, text: text); defer { store.board.removeBackup() }
        let match = try tab.document.findString("第200行：", withOptions: []).first.unwrap("没有找到文字")
        let truePage = tab.document.index(for: try match.pages.first.unwrap("没有页面"))
        XCTAssertTrue(truePage > 2)
        let anchor = try match.string.unwrap("没有文字")
        // The card says page 1, but the words are on a later page.
        tab.go(to: ViewPosition(selection: 0, x: 10, y: 20, scale: nil), anchor: anchor)
        XCTAssertEqual(tab.selection, truePage)
        // With the right page recorded, nothing is searched for.
        tab.go(to: ViewPosition(selection: truePage, x: 10, y: 20, scale: nil), anchor: anchor)
        XCTAssertEqual(tab.selection, truePage)
        // An anchor that is nowhere keeps the recorded page.
        tab.go(to: ViewPosition(selection: 1, x: 10, y: 20, scale: nil), anchor: "根本没有这段文字")
        XCTAssertEqual(tab.selection, 1)
    }

    @MainActor func testRevealCarriesTheAnchorToAWaitingTab() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("书.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        let store = WorkspaceStore(storage: directory); store.bootstrap(); defer { store.board.removeBackup() }
        let tab = try store.activeWorkspace.unwrap("没有标签页")
        tab.sourceURL = url; tab.needsLoad = true
        let source = SourceRef(path: url.path, fileName: "书.pdf", page: 1, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)], anchor: "学而")
        XCTAssertTrue(store.reveal(source))
        XCTAssertEqual(tab.pendingReveal, source)
    }

    // MARK: Arranging

    @MainActor func testArrangeBySourceMakesAColumnPerDocument() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        func ref(_ name: String, _ page: Int, top: CGFloat) -> SourceRef {
            SourceRef(path: "/tmp/\(name)", fileName: name, page: page, rects: [CGRect(x: 0, y: top - 10, width: 50, height: 10)])
        }
        let a5 = board.addExcerpt(text: "甲书第五页", source: ref("甲.pdf", 4, top: 700))
        let b1 = board.addExcerpt(text: "乙书第一页", source: ref("乙.pdf", 0, top: 700))
        let a1low = board.addExcerpt(text: "甲书第一页下", source: ref("甲.pdf", 0, top: 300))
        let a1high = board.addExcerpt(text: "甲书第一页上", source: ref("甲.pdf", 0, top: 700))
        let note = board.addNote(text: "笔记")
        board.arrangeBySource()
        let column = { (id: UUID) in board.card(id)?.x ?? -1 }
        XCTAssertEqual(column(a5), column(a1low)); XCTAssertEqual(column(a5), column(a1high))
        XCTAssertTrue(column(b1) > column(a5))
        XCTAssertTrue(column(note) > column(b1))
        // Reading order inside a column: page 1 top, page 1 lower, then page 5.
        let ys = [a1high, a1low, a5].map { board.card($0)?.y ?? -1 }
        XCTAssertTrue(ys[0] < ys[1] && ys[1] < ys[2])
        XCTAssertTrue(board.canUndoArrangement)
        board.undoArrangement()
        XCTAssertEqual(board.card(a1high)?.x, 40)   // back where each card was put
        XCTAssertFalse(board.canUndoArrangement)
    }

    @MainActor func testMovingACardForgetsTheArrangementUndo() throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        let a = board.addNote(text: "甲"); board.addNote(text: "乙")
        board.arrangeBySource()
        XCTAssertTrue(board.canUndoArrangement)
        board.move(a, to: CGPoint(x: 500, y: 500))
        XCTAssertFalse(board.canUndoArrangement)
    }

    @MainActor func testFocusClearsItself() async throws {
        defer { resetDefaults() }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        let id = board.addNote(text: "甲")
        board.focus(id)
        XCTAssertEqual(board.focusedID, id)
        for _ in 0..<200 where board.focusedID != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(board.focusedID)
    }

    func testOldBoardFilesWithoutAnAnchorStillLoad() throws {
        let json = #"{"path":"/tmp/a.pdf","fileName":"a.pdf","page":3,"rects":[]}"#
        let ref = try JSONDecoder().decode(SourceRef.self, from: Data(json.utf8))
        XCTAssertNil(ref.anchor)
        XCTAssertEqual(ref.page, 3)
    }
}
