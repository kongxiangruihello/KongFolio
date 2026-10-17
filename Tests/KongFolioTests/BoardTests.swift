import XCTest
import PDFKit
@testable import KongFolio

final class BoardTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func source(_ page: Int = 2, name: String = "论语.pdf", path: String = "/tmp/论语.pdf") -> SourceRef {
        SourceRef(path: path, fileName: name, page: page, pageLabel: "15", rects: [CGRect(x: 10, y: 20, width: 50, height: 10)])
    }

    // MARK: Text and geometry

    func testExcerptTextJoinsLinesLikeAReader() {
        XCTAssertEqual(ExcerptText.tidy("学而时习之，\n不亦说乎？"), "学而时习之，不亦说乎？")
        XCTAssertEqual(ExcerptText.tidy("Hello\nworld"), "Hello world")
        XCTAssertEqual(ExcerptText.tidy("第一章\nabc"), "第一章 abc")
        XCTAssertEqual(ExcerptText.tidy("  甲  \n\n  乙\r\n丙 "), "甲乙丙")
        XCTAssertEqual(ExcerptText.tidy("⾃遠⽅來"), "自遠方來")
    }

    func testEdgePointLeavesTheRectangleTowardTheTarget() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(BoardGeometry.edgePoint(of: rect, toward: CGPoint(x: 300, y: 25)), CGPoint(x: 100, y: 25))
        XCTAssertEqual(BoardGeometry.edgePoint(of: rect, toward: CGPoint(x: 50, y: -200)), CGPoint(x: 50, y: 0))
        XCTAssertEqual(BoardGeometry.edgePoint(of: rect, toward: CGPoint(x: 50, y: 25)), CGPoint(x: 50, y: 25))
        let corner = BoardGeometry.edgePoint(of: rect, toward: CGPoint(x: 150, y: 75))
        XCTAssertEqual(Double(corner.x), 100, accuracy: 0.001); XCTAssertEqual(Double(corner.y), 50, accuracy: 0.001)
    }

    func testSourceDescriptionAndPosition() {
        XCTAssertEqual(source(2).pageDescription, "第 3 页（印刷页码 15）")
        XCTAssertEqual(SourceRef(path: "", fileName: "a.pdf", page: 0, pageLabel: "1").pageDescription, "第 1 页")
        XCTAssertEqual(source(2).position, ViewPosition(selection: 2, x: 10, y: 66, scale: nil))
        XCTAssertNil(SourceRef(path: "", fileName: "a.pdf", page: 4).position.point)
    }

    // MARK: Cards

    @MainActor func testNewCardsStackBelowEachOther() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        let first = board.addExcerpt(text: "学而时习之", source: source())
        let second = board.addExcerpt(text: "不亦说乎", source: source(3))
        let a = try board.card(first).unwrap("没有卡片"), b = try board.card(second).unwrap("没有卡片")
        XCTAssertEqual(CGPoint(x: a.x, y: a.y), CGPoint(x: 40, y: 40))
        XCTAssertEqual(b.y, a.y + a.height + 16)
        XCTAssertTrue(b.z > a.z)
        XCTAssertTrue(board.dirty); XCTAssertTrue(board.hasContent)
        XCTAssertTrue(board.canvasSize.width >= 1400 && board.canvasSize.height >= 1000)
    }

    @MainActor func testMovingResizingAndEditingCards() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        let id = board.addNote(text: "想法")
        board.move(id, to: CGPoint(x: -50, y: 120))
        XCTAssertEqual(board.card(id)?.x, 0); XCTAssertEqual(board.card(id)?.y, 120)
        board.resize(id, to: CGSize(width: 10, height: 10))
        XCTAssertEqual(board.card(id)?.width, Board.minimumWidth); XCTAssertEqual(board.card(id)?.height, Board.minimumHeight)
        board.setText(id, "新想法"); board.setComment(id, "批注"); board.setColor(id, .pink)
        XCTAssertEqual(board.card(id)?.text, "新想法"); XCTAssertEqual(board.card(id)?.comment, "批注"); XCTAssertEqual(board.card(id)?.color, .pink)
        let other = board.addExcerpt(text: "x", source: nil)
        board.bringToFront(id)
        XCTAssertTrue((board.card(id)?.z ?? 0) > (board.card(other)?.z ?? 0))
    }

    @MainActor func testImageCardKeepsTheAspectRatio() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        let id = board.addImage(Data([1, 2, 3]), size: CGSize(width: 400, height: 200), source: source())
        let card = try board.card(id).unwrap("没有卡片")
        XCTAssertEqual(card.kind, .image)
        XCTAssertEqual(card.height, (Board.cardWidth - 20) * 0.5 + 70, accuracy: 0.01)
    }

    // MARK: Links

    @MainActor func testLinksAreUniqueAndRemovedWithTheirCards() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory); defer { board.removeBackup() }
        let a = board.addExcerpt(text: "甲", source: nil), b = board.addExcerpt(text: "乙", source: nil), c = board.addNote(text: "丙")
        XCTAssertTrue(board.connect(a, b))
        XCTAssertFalse(board.connect(b, a))     // the same pair in the other direction
        XCTAssertFalse(board.connect(a, a))     // not to itself
        XCTAssertFalse(board.connect(a, UUID())) // not to something that does not exist
        XCTAssertTrue(board.connect(b, c))
        XCTAssertEqual(board.links.count, 2)
        XCTAssertEqual(Set(board.neighbours(of: b).map(\.id)), [a, c])
        board.disconnect(a, b)
        XCTAssertEqual(board.links.count, 1)
        board.remove(c)
        XCTAssertEqual(board.links.count, 0)
        XCTAssertEqual(board.cards.count, 2)
    }

    // MARK: Saving

    @MainActor func testFileRoundTripKeepsEverything() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(title: "读书笔记", storage: directory); defer { board.removeBackup() }
        let a = board.addExcerpt(text: "学而时习之", source: source())
        let b = board.addImage(Data([9, 8, 7]), size: CGSize(width: 100, height: 100), source: source(5))
        board.setComment(a, "孔子的第一句")
        board.connect(a, b)
        let url = directory.appendingPathComponent("读书.kongboard")
        try board.write(to: url)
        XCTAssertFalse(board.dirty); XCTAssertEqual(board.displayTitle, "读书")

        let other = Board(storage: directory); defer { other.removeBackup() }
        other.load(try Board.read(url), from: url)
        XCTAssertEqual(other.cards, board.cards)
        XCTAssertEqual(other.links, board.links)
        XCTAssertEqual(other.card(b)?.imageData, Data([9, 8, 7]))
        XCTAssertEqual(other.card(a)?.source, source())
        XCTAssertFalse(other.dirty)
        XCTAssertThrowsError(try Board.read(directory.appendingPathComponent("不存在.kongboard")))
    }

    @MainActor func testUnsavedWorkIsBackedUpAndRestored() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(storage: directory)
        let a = board.addExcerpt(text: "未保存的摘录", source: source()), b = board.addNote(text: "笔记")
        board.connect(a, b)
        try board.writeBackup()
        let restored = try Board.restoreBackup(storage: directory).unwrap("没有恢复")
        XCTAssertEqual(restored.cards.count, 2); XCTAssertEqual(restored.links.count, 1); XCTAssertTrue(restored.dirty)
        board.removeBackup()
        XCTAssertNil(Board.restoreBackup(storage: directory))
        restored.removeBackup()
    }

    @MainActor func testStoreRestoresTheWorkspaceAtLaunch() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkspaceStore(storage: directory); first.bootstrap()
        first.board.addExcerpt(text: "崩溃前的摘录", source: nil)
        try first.board.writeBackup()
        let second = WorkspaceStore(storage: directory); second.bootstrap()
        XCTAssertEqual(second.board.cards.map(\.text), ["崩溃前的摘录"])
        XCTAssertTrue(second.board.dirty)
        first.board.removeBackup(); second.board.removeBackup()
    }

    // MARK: Export

    @MainActor func testMarkdownQuotesCitesAndListsLinks() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let board = Board(title: "读书笔记", storage: directory); defer { board.removeBackup() }
        let a = board.addExcerpt(text: "学而时习之", source: source(2))
        let b = board.addNote(text: "我的想法")
        board.setComment(a, "第一句")
        board.connect(a, b)
        let text = board.markdown()
        XCTAssertTrue(text.hasPrefix("# 读书笔记"))
        XCTAssertTrue(text.contains("> 学而时习之"))
        XCTAssertTrue(text.contains("> — 论语.pdf，第 3 页（印刷页码 15）"))
        XCTAssertTrue(text.contains("第一句"))
        XCTAssertTrue(text.contains("我的想法"))
        XCTAssertTrue(text.contains("- [1] ↔ [2]"))
    }

    // MARK: Going back to the source

    @MainActor func loadedTab(_ store: WorkspaceStore, path: String) -> Workspace {
        let tab = store.addWorkspace()
        tab.document = DocumentServicesTests().fixture()
        tab.sourceURL = URL(fileURLWithPath: path)
        return tab
    }

    @MainActor func testRevealSelectsTheOpenTabAndGoesToThePlace() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("书.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        let store = WorkspaceStore(storage: directory); store.bootstrap(); defer { store.board.removeBackup() }
        let book = loadedTab(store, path: url.path)
        let other = loadedTab(store, path: directory.appendingPathComponent("别的.pdf").path)
        XCTAssertEqual(store.selectedID, other.id)
        XCTAssertTrue(store.reveal(source(2, name: "书.pdf", path: url.path)))
        XCTAssertEqual(store.selectedID, book.id)
        XCTAssertEqual(book.selection, 2)
        XCTAssertEqual(book.readingPoint, CGPoint(x: 10, y: 66))
    }

    @MainActor func testRevealOfAWaitingTabStartsReadingItAtTheRightPage() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("书.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        let store = WorkspaceStore(storage: directory); store.bootstrap(); defer { store.board.removeBackup() }
        let tab = try store.activeWorkspace.unwrap("没有标签页")
        tab.sourceURL = url; tab.needsLoad = true
        XCTAssertTrue(store.reveal(source(1, name: "书.pdf", path: url.path)))
        XCTAssertFalse(tab.needsLoad)
        XCTAssertTrue(tab.busy)
        XCTAssertEqual(tab.pendingView?.selection, 1)
    }

    @MainActor func testRevealOpensAFileThatIsNotOpenYet() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("新.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        let store = WorkspaceStore(storage: directory); store.bootstrap(); defer { store.board.removeBackup() }
        XCTAssertTrue(store.reveal(source(0, name: "新.pdf", path: url.path)))
        XCTAssertEqual(store.activeWorkspace?.displayName, "新.pdf")
        XCTAssertEqual(store.tabs.count, 1)
    }

    @MainActor func testRevealFailsCleanlyWhenTheFileIsGone() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap(); defer { store.board.removeBackup() }
        XCTAssertFalse(store.reveal(source(0, path: directory.appendingPathComponent("没有.pdf").path)))
        XCTAssertFalse(store.reveal(SourceRef(path: "", fileName: "合并文档", page: 0)))
        XCTAssertEqual(store.tabs.count, 1)
    }

    @MainActor func testExcerptNeedsASelectionAndAWorkspace() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap(); defer { store.board.removeBackup() }
        let tab = try store.activeWorkspace.unwrap("没有标签页")
        tab.document = DocumentServicesTests().fixture()
        tab.excerptSelection()
        XCTAssertNotNil(tab.error)
        XCTAssertEqual(store.board.cards.count, 0)
        let alone = Workspace(storage: directory)
        alone.excerptSelection()
        XCTAssertEqual(alone.error, "工作区不可用。")
    }

    func testRegionToolIsListed() {
        XCTAssertTrue(AnnotationTool.allCases.contains(.region))
        XCTAssertFalse(AnnotationTool.region.draws)
    }
}
