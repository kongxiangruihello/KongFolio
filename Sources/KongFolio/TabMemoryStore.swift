import Foundation
import PDFKit

/// Undo entries on disk contain independent, one-page PDFs, never native annotation/page objects.
enum TabMemoryStore {
    struct Change: Codable {
        let page: Int
        let id: String
        let before: Data?
        let after: Data?
        static func data(_ annotation: PDFAnnotation?) throws -> Data? {
            guard let annotation else { return nil }
            let page = PDFPage()
            page.setBounds(CGRect(x: -10000, y: -10000, width: 20000, height: 20000), for: .mediaBox)
            guard let copy = annotation.copy() as? PDFAnnotation else { throw FolioError(message: "标注撤销记录无法复制") }
            page.addAnnotation(copy)
            let doc = PDFDocument(); doc.insert(page, at: 0)
            return try doc.dataRepresentation().unwrap("标注撤销记录无法保存")
        }
        static func annotation(_ data: Data?, id: String) throws -> (value: PDFAnnotation?, source: PDFDocument?) {
            guard let data else { return (nil, nil) }
            guard let source = PDFDocument(data: data), let page = source.page(at: 0), let annotation = page.annotations.first,
                  let copy = AnnotationIdentity.copy(annotation, id: id) else { throw FolioError(message: "标注撤销记录无法恢复，缓存已保留") }
            return (copy, source)
        }
    }

    struct Entry: Codable {
        let snapshot: ProjectArchive?
        let changes: [Change]?
        init(_ entry: UndoEntry) throws {
            switch entry {
            case .snapshot(let archive): snapshot = archive; changes = nil
            case .annotations(let items):
                snapshot = nil
                changes = try items.map { Change(page: $0.page, id: $0.id, before: try Change.data($0.before), after: try Change.data($0.after)) }
            }
        }
        func restore() throws -> UndoEntry {
            if let snapshot { try snapshot.validate(); return .snapshot(snapshot) }
            guard let changes else { throw FolioError(message: "撤销缓存无效") }
            return .annotations(try changes.map { change in
                let before = try Change.annotation(change.before, id: change.id), after = try Change.annotation(change.after, id: change.id)
                return AnnotationChange(page: change.page, id: change.id, before: before.value, after: after.value,
                    resourceDocuments: [before.source, after.source].compactMap { $0 })
            })
        }
    }
    struct Session: Codable {
        let archive: ProjectArchive
        let history: [Entry]
        let future: [Entry]
    }
    static func write(_ value: Session, to url: URL) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func read(_ url: URL) throws -> (Session, [UndoEntry], [UndoEntry], Bool) {
        let value = try PropertyListDecoder().decode(Session.self, from: Data(contentsOf: url))
        try value.archive.validate()
        let changed: Bool
        if let baseline = value.archive.fileBaseline { changed = (try? baseline.verify(URL(fileURLWithPath: baseline.path))) == nil }
        else { changed = true }
        return (value, try value.history.map { try $0.restore() }, try value.future.map { try $0.restore() }, changed)
    }
}

extension Workspace {
    func beginUnload() {
        guard canUnload else { return }
        // Unedited files need no spill; keep the inexpensive path for large batches of read-only books.
        if history.isEmpty && future.isEmpty && !hasPrivateReadingData {
            pendingView = currentViewPosition()
            clearDocument(keepingSource: true); needsLoad = true
            return
        }
        do {
            let position = currentViewPosition(), version = revision, privateVersion = privateDataGeneration
            let value = try TabMemoryStore.Session(archive: snapshot(), history: history.map { try TabMemoryStore.Entry($0) }, future: future.map { try TabMemoryStore.Entry($0) })
            let file = storage.appendingPathComponent("TabCache", isDirectory: true).appendingPathComponent(id.uuidString + ".plist")
            let recovery = recoveryURL
            unloadWorker = Task { [weak self] in
                do {
                    try await Task.detached(priority: .utility) {
                        try TabMemoryStore.write(value, to: file)
                        try RecoveryWriter.shared.flush(value.archive, to: recovery)

                    }.value
                    guard let self else { return }
                    defer { self.unloadWorker = nil }
                    let visible = self.store.map { store in
                        store.selectedID == self.id || store.tabs.compactMap(\.workspace).contains { $0.splitPartner?.id == self.id }
                    } ?? false
                    guard self.revision == version, self.privateDataGeneration == privateVersion, !self.dirty, !self.saving, !visible, !self.busy else {
                        try? FileManager.default.removeItem(at: file); return
                    }
                    self.pendingView = position; self.spilledSession = file
                    self.clearDocument(keepingSource: true); self.needsLoad = true
                    self.status = "已释放内存；再次选中时恢复阅读资料和撤销历史"
                } catch { self?.unloadWorker = nil; self?.error = "内存缓存未完成，文档仍保留：" + error.localizedDescription }
            }
        } catch { self.error = "无法缓存撤销历史，文档仍保留：" + error.localizedDescription }
    }

    func restoreSpilledSession() {
        guard let file = spilledSession else { return }
        busy = true; taskLabel = "恢复标签页…"
        Task { [weak self] in
            do {
                let (value, undo, redo, externallyChanged) = try await Task.detached { try TabMemoryStore.read(file) }.value
                guard let self else { return }
                try self.restore(value.archive)
                self.history = undo; self.future = redo
                self.annotationResourceDocuments = (undo + redo).flatMap { entry -> [PDFDocument] in
                    if case .annotations(let changes) = entry { return changes.flatMap(\.resourceDocuments) }; return []
                }
                self.needsLoad = false
                self.dirty = externallyChanged; self.saveConflict = externallyChanged
                self.spilledSession = nil; self.pendingView = nil
                try? FileManager.default.removeItem(at: file)
                self.status = externallyChanged ? "原文件已有变化，已保留缓存中的阅读资料和撤销；请另存副本或重新载入原文件。" : "已恢复阅读资料和撤销历史"
                self.busy = false; self.store?.loadedTabsChanged()
            } catch {
                self?.busy = false
                self?.error = "标签页缓存未能恢复，缓存已保留：" + error.localizedDescription
            }
        }
    }
}
