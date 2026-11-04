import XCTest
import AppKit
@testable import KongFolio

final class DraftNoteNameTests: XCTestCase {
    func testNamesTrimWhitespaceAndAvoidDuplicateExtensions() throws {
        XCTAssertEqual(try DraftNoteName.normalized("  文献札记.MD  ",extension:"md"),"文献札记")
        XCTAssertEqual(try DraftNoteName.normalized("札记.v1",extension:"txt"),"札记.v1")
        for name in ["","  ",".","..",".md","../资料","甲:乙","甲\n乙",String(repeating:"史",count:100)] { XCTAssertThrowsError(try DraftNoteName.normalized(name,extension:"md")) }
    }
    @MainActor func testDraftNameCanChangeInReadingModeWithoutChangingBody() throws {
        let root = try Release027Tests().folder(),note = MarkdownNote(text:"原文😀\n- 第一行\n- 第二行",storage:root)
        note.readOnly = true
        let original = note.text;try note.renameDraft(to:"研究札记")
        XCTAssertEqual(note.title,"研究札记");XCTAssertEqual(note.text,original);XCTAssertTrue(note.readOnly);XCTAssertTrue(note.dirty);XCTAssertNil(note.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath:note.backupURL.path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("研究札记.md").path))
    }
    @MainActor func testDraftNameAndBodySurviveRecoveryAndSaving() throws {
        let root = try Release027Tests().folder(),note = MarkdownNote(text:"正文与出处",dirty:true,storage:root)
        try note.renameDraft(to:"近代史札记.md")
        let restored = try XCTUnwrap(MarkdownNote.restoreBackups(storage:root).first)
        XCTAssertEqual(restored.title,"近代史札记");XCTAssertEqual(restored.text,"正文与出处")
        let file = root.appendingPathComponent(restored.title+"."+restored.format.fileExtension)
        try restored.write(to:file)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"正文与出处");XCTAssertEqual(restored.title,"近代史札记");XCTAssertFalse(restored.dirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:restored.backupURL.path))
    }
    @MainActor func testInvalidNameDoesNotChangeDraftOrBackup() throws {
        let root = try Release027Tests().folder(),note = MarkdownNote(text:"保留正文",storage:root)
        try note.renameDraft(to:"有效标题");let before = try Data(contentsOf:note.backupURL)
        XCTAssertThrowsError(try note.renameDraft(to:"../错误"));XCTAssertEqual(note.title,"有效标题");XCTAssertEqual(note.text,"保留正文");XCTAssertEqual(try Data(contentsOf:note.backupURL),before)
    }
    @MainActor func testOldBackupsWithoutDraftNameRemainReadable() throws {
        let root = try Release027Tests().folder(),id = UUID(),folder = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let old = "{\"id\":\""+id.uuidString+"\",\"text\":\"旧版本正文\"}"
        try old.write(to:folder.appendingPathComponent(id.uuidString+".json"),atomically:true,encoding:.utf8)
        let note = try XCTUnwrap(MarkdownNote.restoreBackups(storage:root).first)
        XCTAssertEqual(note.title,"未命名笔记");XCTAssertEqual(note.text,"旧版本正文")
    }
    @MainActor func testSavedFileIsNotRenamedOrRewrittenByDraftNaming() throws {
        let root = try Release027Tests().folder(),file = root.appendingPathComponent("原件.md")
        try "原件正文".write(to:file,atomically:true,encoding:.utf8)
        let note = try MarkdownNote.open(file,storage:root)
        XCTAssertThrowsError(try note.renameDraft(to:"新名称"));XCTAssertEqual(note.title,"原件");XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"原件正文");XCTAssertFalse(note.dirty)
    }
}
