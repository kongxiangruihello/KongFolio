import XCTest
import PDFKit
@testable import KongFolio

final class TabsAndNotesTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Formatting edits

    func testWrapEdit() {
        let wrapped = MarkdownNote.wrapEdit(in: "你好 世界", selection: NSRange(location: 0, length: 2), prefix: "**", suffix: "**", placeholder: "粗体")
        XCTAssertEqual(wrapped, TextEdit(range: NSRange(location: 0, length: 2), replacement: "**你好**", selection: NSRange(location: 2, length: 2)))
        let placeholder = MarkdownNote.wrapEdit(in: "ab", selection: NSRange(location: 1, length: 0), prefix: "[", suffix: "](https://)", placeholder: "链接文字")
        XCTAssertEqual(placeholder.replacement, "[链接文字](https://)")
        XCTAssertEqual(placeholder.selection, NSRange(location: 2, length: 4))
        let outside = MarkdownNote.wrapEdit(in: "ab", selection: NSRange(location: 99, length: 5), prefix: "`", suffix: "`", placeholder: "代码")
        XCTAssertEqual(outside.range, NSRange(location: 2, length: 0))
    }

    func testLineEditAddsAndTogglesPrefix() {
        let text = "甲\n乙\n"
        let added = MarkdownNote.lineEdit(in: text, selection: NSRange(location: 0, length: 3), prefix: "- ")
        XCTAssertEqual(added.replacement, "- 甲\n- 乙\n")
        XCTAssertEqual(added.range, NSRange(location: 0, length: 4))
        let removed = MarkdownNote.lineEdit(in: "- 甲\n- 乙\n", selection: NSRange(location: 0, length: 6), prefix: "- ")
        XCTAssertEqual(removed.replacement, "甲\n乙\n")
        let mixed = MarkdownNote.lineEdit(in: "- 甲\n乙", selection: NSRange(location: 0, length: 6), prefix: "- ")
        XCTAssertEqual(mixed.replacement, "- - 甲\n- 乙")
    }

    func testLineEditOnEmptyLinesAndEmptyText() {
        XCTAssertEqual(MarkdownNote.lineEdit(in: "", selection: NSRange(location: 0, length: 0), prefix: "# ").replacement, "# ")
        XCTAssertEqual(MarkdownNote.lineEdit(in: "a\n\nb", selection: NSRange(location: 2, length: 0), prefix: "> ").replacement, "> \n")
        // Blank lines inside a block are left alone when other lines are touched.
        XCTAssertEqual(MarkdownNote.lineEdit(in: "a\n\nb", selection: NSRange(location: 0, length: 4), prefix: "- ").replacement, "- a\n\n- b")
    }

    // MARK: Notes

    @MainActor func testNoteSaveOpenAndTitle() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let note = MarkdownNote(storage: directory)
        XCTAssertEqual(note.title, "未命名笔记"); XCTAssertFalse(note.dirty)
        note.text = "# 论语\r\n\r\n学而时习之"
        XCTAssertTrue(note.dirty)
        let url = directory.appendingPathComponent("论语.md")
        try note.write(to: url)
        XCTAssertFalse(note.dirty); XCTAssertEqual(note.title, "论语")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# 论语\r\n\r\n学而时习之")
        let reopened = try MarkdownNote.open(url, storage: directory)
        XCTAssertEqual(reopened.text, "# 论语\n\n学而时习之")
        XCTAssertFalse(reopened.dirty)
    }

    @MainActor func testNoteOpensLegacyEncodedFile() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("旧文件.txt")
        try "学而时习之".data(using: TextImport.gb18030)!.write(to: url)
        XCTAssertEqual(try MarkdownNote.open(url, storage: directory).text, "学而时习之")
    }

    // Unsaved text survives a crash: it is restored as a dirty note, and saving removes the backup.
    @MainActor func testUnsavedTextIsBackedUpAndRestored() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let note = MarkdownNote(storage: directory)
        note.text = "还没有保存的想法"
        try note.writeBackup()
        let restored = MarkdownNote.restoreBackups(storage: directory)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, note.id); XCTAssertEqual(restored[0].text, "还没有保存的想法"); XCTAssertTrue(restored[0].dirty)
        try note.write(to: directory.appendingPathComponent("a.md"))
        XCTAssertEqual(MarkdownNote.restoreBackups(storage: directory).count, 0)
    }

    // MARK: Tabs

    @MainActor func testBootstrapCreatesOneEmptyTab() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeWorkspace?.count, 0)
        XCTAssertFalse(store.canSave); XCTAssertFalse(store.canCloseActive)
    }

    @MainActor func testNewNoteTabAndClose() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let first = try store.activeWorkspace.unwrap("没有标签页")
        let note = store.newNote()
        XCTAssertEqual(store.tabs.count, 2); XCTAssertEqual(store.selectedID, note.id)
        XCTAssertTrue(store.canSave)
        store.close(note.id)
        XCTAssertEqual(store.tabs.count, 1); XCTAssertEqual(store.selectedID, first.id)
        // The last tab is never removed.
        store.close(first.id)
        XCTAssertEqual(store.tabs.count, 1)
    }

    // A document that is open stays open: another file goes to a new tab.
    @MainActor func testLoadingWhileADocumentIsOpenUsesANewTab() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("b.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let first = try store.activeWorkspace.unwrap("没有标签页")
        first.document = DocumentServicesTests().fixture()
        first.load([url])
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertTrue(store.selectedID != first.id)
        XCTAssertEqual(first.count, 3)
    }

    // An empty tab is reused instead of opening yet another one.
    @MainActor func testEmptyTabIsReused() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("c.pdf")
        try DocumentServicesTests().fixture().dataRepresentation()!.write(to: url)
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        store.openInNewTab([url])
        XCTAssertEqual(store.tabs.count, 1)
    }

    @MainActor func testSessionRestoresEveryDocumentTab() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let first = try store.activeWorkspace.unwrap("没有标签页")
        first.document = DocumentServicesTests().fixture()
        let second = store.addWorkspace()
        second.document = DocumentServicesTests().fixture()
        XCTAssertTrue(first.slot != second.slot)
        XCTAssertTrue(first.flushRecovery()); XCTAssertTrue(second.flushRecovery())
        store.saveSession()

        let restored = WorkspaceStore(storage: directory); restored.bootstrap()
        XCTAssertEqual(restored.tabs.compactMap(\.workspace).map(\.count), [3, 3])
        XCTAssertEqual(restored.tabs.compactMap(\.workspace).map(\.slot), [first.slot, second.slot])
    }

    @MainActor func testClosedDocumentIsNotRestored() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(storage: directory); store.bootstrap()
        let first = try store.activeWorkspace.unwrap("没有标签页")
        first.document = DocumentServicesTests().fixture()
        XCTAssertTrue(first.flushRecovery())
        let second = store.addWorkspace()
        second.document = DocumentServicesTests().fixture()
        XCTAssertTrue(second.flushRecovery())
        store.close(second.id)
        XCTAssertEqual(store.tabs.count, 1)
        store.saveSession()
        let restored = WorkspaceStore(storage: directory); restored.bootstrap()
        XCTAssertEqual(restored.tabs.compactMap(\.workspace).map(\.count), [3])
    }
}
