import Foundation
import PDFKit
import AppKit

/// Runs without XCTest, because the app intentionally disables timed original-file saves in XCTest.
@main struct AutosaveRunner {
    @MainActor static func waitFor(_ condition: () -> Bool, label: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard condition() else { throw FolioError(message: "验证失败：" + label) }
    }
    @MainActor static func main() async throws {
        guard !AppEnvironment.isTestRun else { throw FolioError(message: "必须在正常运行模式验证自动保存") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-Autosave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PDFDocument(); document.insert(PDFPage(), at: 0)
        let file = root.appendingPathComponent("rotation.pdf"); try document.dataRepresentation()!.write(to: file)
        let w = Workspace(storage: root, readingDefaults: UserDefaults(suiteName: "KongFolio.NormalAutosave." + UUID().uuidString)!)
        w.bootstrap(); w.load([file], prepared: .documents([try Data(contentsOf: file)]))
        w.rotate()
        try await waitFor({ !w.dirty && PDFDocument(url: file)?.page(at: 0)?.rotation == 90 }, label: "旋转自动保存")
        w.undo()
        try await waitFor({ !w.dirty && PDFDocument(url: file)?.page(at: 0)?.rotation == 0 }, label: "快照撤销自动保存")
        w.redo()
        try await waitFor({ !w.dirty && PDFDocument(url: file)?.page(at: 0)?.rotation == 90 }, label: "快照重做自动保存")
        w.bookmarkName = "关闭重开的书签"; w.addBookmark()
        try await waitFor({ !w.dirty && !w.saving }, label: "书签自动保存")
        guard await w.finishPendingSave(), w.closeDocument() else { throw FolioError(message: "关闭前保存失败") }
        let reopened = Workspace(storage: root, slot: "reopen")
        reopened.bootstrap(); reopened.load([file], prepared: .documents([try Data(contentsOf: file)]))
        guard reopened.bookmarks.map(\.label) == ["关闭重开的书签"], reopened.document.page(at: 0)?.rotation == 90 else { throw FolioError(message: "重开资料不一致") }
        _ = reopened.closeDocument()
        let store = WorkspaceStore(storage: root.appendingPathComponent("store"), readingDefaults: UserDefaults(suiteName: "KongFolio.CloseNormal." + UUID().uuidString)!)
        store.bootstrap(); store.openEach([file])
        try await waitFor({ store.activeWorkspace?.busy == false && store.activeWorkspace?.count == 1 }, label: "正常模式载入标签页")
        let closing = store.activeWorkspace!
        closing.bookmarkName = "关闭前最后修改"; closing.addBookmark()
        store.close(closing.id)
        try await waitFor({ closing.count == 0 && !closing.saving }, label: "正常模式关闭自动等待保存")
        let check = Workspace(storage: root.appendingPathComponent("store"), slot: "verify")
        check.bootstrap(); check.load([file], prepared: .documents([try Data(contentsOf: file)]))
        guard check.bookmarks.contains(where: { $0.label == "关闭前最后修改" }) else { throw FolioError(message: "关闭标签页遗漏最后修改") }
        _ = check.closeDocument()
        let report: [String: Any] = ["testMode": false, "rotationAutosave": true, "snapshotUndoAutosave": true,
            "snapshotRedoAutosave": true, "bookmarkAutosaveAndReopen": true, "closeWaitedForSave": true, "normalStoreClose": true]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_AUTOSAVE_REPORT"] { try json.write(to: URL(fileURLWithPath: path), options: .atomic) }
        print(String(data: json, encoding: .utf8)!)
        print("PASS: normal-mode autosave, undo, redo and reopen")
    }
}
