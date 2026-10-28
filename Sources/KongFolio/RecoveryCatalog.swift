import AppKit
import PDFKit

struct RecoveryItem: Identifiable {
    enum Kind: String { case conflictPDF = "冲突副本", conflictText = "文本冲突副本", word = "Word 修改草稿", table = "表格草稿", recovery = "文档恢复副本", note = "未保存文本" }
    var url: URL
    var kind: Kind
    var title: String
    var sourcePath: String?
    var modified: Date
    var id: String { url.path }
}
enum RecoveryOpenPayload {
    case archive(ProjectArchive), note(MarkdownNote.Backup), word(String), table(TableDraftRecord, Data?)
}
struct RecoveryPreview {
    var payload: RecoveryOpenPayload?
    var text = ""
    var pdf: Data?
    var original: Data?
    var differences: [PageDifference] = []
    var sourceStatus = "未记录原件位置"
}
enum RecoveryCatalog {
    /// Reads only the manifest, so listing a large PDF backup does not load its binary payload.
    static func archiveHeader(_ url: URL) throws -> ProjectArchive {
        var directory: ObjCBool = false
        let data: Data
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        } else {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let prefix = try handle.read(upToCount: ProjectContainer.magic.count + 8) ?? Data()
            if prefix.starts(with: ProjectContainer.magic), prefix.count == ProjectContainer.magic.count + 8 {
                let length = prefix.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard length <= 16_000_000 else { throw FolioError(message: "恢复记录的目录过大") }
                data = try handle.read(upToCount: Int(length)) ?? Data()
            } else {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8_000_000 else { throw FolioError(message: "旧格式记录需选择后查看") }
                try handle.seek(toOffset: 0); return try JSONDecoder().decode(ProjectArchive.self, from: handle.readToEnd() ?? Data())
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let archive = json["archive"] else { throw FolioError(message: "恢复记录目录无法读取") }
        return try JSONDecoder().decode(ProjectArchive.self, from: JSONSerialization.data(withJSONObject: archive))
    }
    static func list(storage: URL, knownPaths: [String] = []) throws -> [RecoveryItem] {
        guard FileManager.default.fileExists(atPath: storage.path) else { return [] }
        let fm = FileManager.default
        var paths = knownPaths
        if let data = try? Data(contentsOf: storage.appendingPathComponent("Recent.json")), let recent = try? JSONDecoder().decode([String].self, from: data) { paths += recent }
        var items: [RecoveryItem] = []
        for (folder, kind) in [("Conflicts", RecoveryItem.Kind.conflictPDF), ("WordDrafts", .word), ("TableDrafts", .table), ("Notes", .note)] {
            let directory = storage.appendingPathComponent(folder)
            guard fm.fileExists(atPath: directory.path) else { continue }
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .fileSizeKey]) {
                try Task.checkCancellation()
                let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true, ["json", "kongfolio"].contains(url.pathExtension) else { continue }
                var item = RecoveryItem(url: url, kind: kind, title: url.lastPathComponent, modified: info.contentModificationDate ?? .distantPast)
                if kind == .conflictPDF {
                    item.kind = url.pathExtension == "json" ? .conflictText : .conflictPDF
                    if url.pathExtension == "kongfolio", let archive = try? archiveHeader(url) { item.title = archive.title; item.sourcePath = archive.projectPath ?? archive.sourcePath }
                }
                if (info.fileSize ?? 0) <= 8_000_000, url.pathExtension == "json", let data = try? Data(contentsOf: url) {
                    if kind == .table, let draft = try? JSONDecoder().decode(TableDraftRecord.self, from: data) {
                        item.title = draft.sourceTitle + " · 第 \(draft.page + 1) 页"; item.sourcePath = draft.sourcePath; item.modified = draft.modified
                    } else if kind == .word, let draft = try? JSONDecoder().decode(WordDraftArchive.self, from: data) {
                        let legacy = paths.first { OCRPageCache.digest(Data(URL(fileURLWithPath: $0).standardizedFileURL.path.utf8)) == url.deletingPathExtension().lastPathComponent }
                        item.sourcePath = draft.sourcePath ?? legacy; item.title = draft.sourceTitle ?? item.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未命名 Word 草稿"
                        item.modified = draft.modified ?? item.modified
                    } else if let note = try? JSONDecoder().decode(MarkdownNote.Backup.self, from: data) {
                        item.sourcePath = note.path; item.title = note.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未命名文本"
                    }
                }
                items.append(item)
            }
        }
        for url in try fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) where url.lastPathComponent.hasPrefix("Recovery") && ["kfrecovery", "kongfolio"].contains(url.pathExtension) {
            let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]); guard info.isSymbolicLink != true else { continue }
            let archive = try? archiveHeader(url)
            items.append(RecoveryItem(url: url, kind: .recovery, title: archive?.title ?? url.lastPathComponent, sourcePath: archive?.projectPath ?? archive?.sourcePath, modified: info.contentModificationDate ?? .distantPast))
        }
        return items.sorted { $0.modified > $1.modified }
    }
    static func sourceData(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        return url.pathExtension.lowercased() == "kongfolio" ? try ProjectArchive.read(url).pdf : try ImportServices.documentData(url)
    }
    static func preview(_ item: RecoveryItem) throws -> RecoveryPreview {
        try Task.checkCancellation(); var result = RecoveryPreview(), source = item.sourcePath, digest: String?
        var tableDraft: TableDraftRecord?
        switch item.kind {
        case .conflictPDF, .recovery:
            let archive = try ProjectArchive.read(item.url); result.payload = .archive(archive); result.pdf = archive.pdf; source = archive.projectPath ?? archive.sourcePath
            result.text = archive.title + " · 文档恢复副本"; digest = OCRPageCache.digest(archive.pdf)
        case .word:
            let archive = try JSONDecoder().decode(WordDraftArchive.self, from: Data(contentsOf: item.url))
            result.text = archive.options.draftText; digest = archive.digest; result.payload = .word(result.text)
        case .table:
            let draft = try TableDraftStore.read(item.url); tableDraft = draft; result.payload = .table(draft, nil); result.text = "第 \(draft.page + 1) 页起 · \(draft.rows.count) 行 × \(draft.columns) 列\n\n" + ExtractedTable(rows: draft.rows).markdown; digest = draft.sourceDigest
        case .conflictText, .note:
            let note = try JSONDecoder().decode(MarkdownNote.Backup.self, from: Data(contentsOf: item.url)); result.text = note.text; result.payload = .note(note)
            if let path = note.path, FileManager.default.fileExists(atPath: path) {
                result.sourceStatus = (try FileBaseline.capture(URL(fileURLWithPath: path))).digest == note.fileBaseline?.digest ? "原件内容与备份基线一致" : "原件已变化，可打开副本核对"
            } else { result.sourceStatus = "原件不存在；备份内容可单独打开" }
            return result
        }
        if let source {
            if FileManager.default.fileExists(atPath: source) {
                do {
                    let data = try sourceData(source)
                    if let tableDraft, OCRPageCache.digest(data) == tableDraft.sourceDigest { result.payload = .table(tableDraft, data) }
                    result.sourceStatus = OCRPageCache.digest(data) == digest ? "原件内容一致，可继续整理" : "副本与目前原件不同，请核对后使用"
                    if result.pdf != nil { result.original = data; result.differences = try PDFComparison.compare(result.pdf!, data) }
                } catch is CancellationError { throw CancellationError() }
                catch { result.sourceStatus = "原件无法读取，恢复内容仍保留" }
            } else { result.sourceStatus = "原件已移动或删除；恢复内容仍可打开" }
        }
        return result
    }
}

extension WorkspaceStore {
    /// Always creates independent unsaved tabs, never binds a recovered copy to its old save destination.
    func openRecoveryCopy(_ item: RecoveryItem, payload: RecoveryOpenPayload? = nil) throws {
        let ready = try payload ?? RecoveryCatalog.preview(item).payload.unwrap("无法读取恢复内容")
        switch ready {
        case .archive(var archive):
            archive.sourcePath = nil; archive.projectPath = nil; archive.fileBaseline = nil; archive.title += "-恢复副本"; archive.dirty = true
            let w = addWorkspace(); try w.restore(archive); w.status = "恢复副本已打开；保存时请选择新位置"; w.scheduleRecovery()
        case .word(let text):
            let note = newNote(); note.text = text; note.status = "Word 草稿已作为独立文本打开，原稿保留"; try note.writeBackup()
        case .table(let draft, let data):
            if let data {
                let w = addWorkspace(); try w.restore(ProjectArchive(pdf: data, title: draft.sourceTitle + "-表格恢复副本", selection: draft.page, selectedPages: [draft.page], mode: .document, recipes: [:], drafts: [:], dirty: true, projectPath: nil)); w.cachedPDF = data
                var copy = draft; copy.id = UUID(); copy.identity = w.tableIdentity; copy.sourcePath = nil; copy.sourceTitle = w.title
                w.tableDrafts = [copy]; try w.persistTableDrafts(); w.pendingTableDraftID = copy.id; w.showTableExtraction = true; w.scheduleRecovery()
            } else {
                let note = newNote(); note.text = "# 表格恢复草稿\n\n" + ExtractedTable(rows: draft.rows).markdown; note.status = "原件已变化或缺失，已打开可单独使用的表格副本"; try note.writeBackup()
            }
        case .note(let backup):
            let note = newNote(format: backup.format ?? .markdown); note.recoveryBaseURL = backup.resourceBasePath.map { URL(fileURLWithPath: $0) } ?? backup.path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }; note.text = backup.text; if let layout = backup.layoutOptions, layout.valid { note.layoutOptions = layout }; note.status = "已打开独立恢复副本，原稿保留"; try note.writeBackup()
        }
    }
}
