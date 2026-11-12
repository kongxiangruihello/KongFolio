import AppKit
import UniformTypeIdentifiers

struct ReadingOpenBatch: Codable, Equatable {
    static let key = "KongFolio.lastReadingBatch"
    struct Entry: Codable, Equatable, Identifiable {
        enum Status: String, Codable {
            case pending = "待读", finished = "已读完", skipped = "稍后处理", failed = "读取失败"
        }
        let id: UUID
        var path: String
        var status = Status.pending
        var position: ViewPosition?
        var message: String?
        var title: String { URL(fileURLWithPath:path).lastPathComponent }
    }
    var entries: [Entry]
    var current: UUID?
    var next: Entry? {
        entries.first{$0.id == current && $0.status == .pending} ?? entries.first{$0.status == .pending}
    }
    static func load(_ defaults:UserDefaults) -> Self? {
        defaults.data(forKey:key).flatMap{try? JSONDecoder().decode(Self.self,from:$0)}
    }
    func entry(_ path:String?) -> Entry? {
        guard let path else { return nil }
        let key = ReadingBookIdentity.key(path)
        return entries.first{ReadingBookIdentity.key($0.path) == key}
    }
}

enum ReadingOpenFailure: LocalizedError {
    case missing, encrypted, malformed, cloud(String)
    var errorDescription: String? {
        switch self {
        case .missing: return "找不到原文件，可能已移动，请重新定位"
        case .encrypted: return "这份 PDF 需要密码，请先用原密码解锁"
        case .malformed: return "这份 PDF 无法解析，文件可能损坏"
        case .cloud(let detail): return "云文件尚未下载完成 · "+detail
        }
    }
}

extension WorkspaceStore {
    func setReadingBatch(_ batch:ReadingOpenBatch) {
        guard readingBatch != batch else { return }
        readingBatch = batch
        if let data = try? JSONEncoder().encode(batch) { readingDefaults.set(data,forKey:ReadingOpenBatch.key) }
    }

    func startReadingBatch(_ urls:[URL]) {
        var seen = Set<String>()
        let entries = urls.filter { url in
            url.isFileURL && ["pdf","kongfolio"].contains(url.pathExtension.lowercased()) &&
                seen.insert(ReadingBookIdentity.key(url.path)).inserted
        }.map{ReadingOpenBatch.Entry(id:UUID(),path:$0.path)}
        if entries.count > 1 { setReadingBatch(ReadingOpenBatch(entries:entries,current:entries.first?.id)) }
    }

    func updateBatchEntry(_ id:UUID,_ edit:(inout ReadingOpenBatch.Entry)->Void) {
        guard var batch = readingBatch,let index = batch.entries.firstIndex(where:{$0.id == id}) else { return }
        edit(&batch.entries[index])
        setReadingBatch(batch)
    }

    func trackBatchSelection(_ workspace:Workspace?) {
        guard let entry = readingBatch?.entry(workspace?.displayPath),entry.status == .pending,
              var batch = readingBatch else { return }
        batch.current = entry.id
        setReadingBatch(batch)
    }

    func captureBatchPosition(_ workspace:Workspace) {
        guard workspace.count > 0,!workspace.browsingReadingReference,
              let entry = readingBatch?.entry(workspace.displayPath) else { return }
        let position = workspace.currentViewPosition()
        updateBatchEntry(entry.id) { $0.position = position }
    }

    func recordBatchLoad(_ workspace:Workspace,error:Error? = nil) {
        guard let entry = readingBatch?.entry(workspace.displayPath),entry.status != .skipped else { return }
        if let error {
            updateBatchEntry(entry.id) { $0.status = .failed; $0.message = error.localizedDescription }
        } else if workspace.count > 0,entry.status == .failed {
            updateBatchEntry(entry.id) { $0.status = .pending; $0.message = nil }
        }
    }

    func resumeReadingBatch() {
        guard let batch = readingBatch,let next = batch.next else { return }
        let pending = batch.entries.filter{$0.status == .pending && $0.id != next.id}
        openEach(([next]+pending).map{URL(fileURLWithPath:$0.path)},startBatch:false)
    }

    func openReadingBatchEntry(_ entry:ReadingOpenBatch.Entry) {
        if entry.status != .finished { updateBatchEntry(entry.id) { $0.status = .pending; $0.message = nil } }
        openEach([URL(fileURLWithPath:entry.path)],startBatch:false)
    }

    func skipReadingBatchEntry(_ entry:ReadingOpenBatch.Entry) {
        updateBatchEntry(entry.id) { $0.status = .skipped }
        guard let workspace = tabs.compactMap(\.workspace).first(where:{ $0.displayPath.map(ReadingBookIdentity.key) == ReadingBookIdentity.key(entry.path) }) else { return }
        captureBatchPosition(workspace)
        if workspace.count == 0 { close(workspace.id) }
    }

    func locateReadingBatchEntry(_ entry:ReadingOpenBatch.Entry) {
        let panel = DocumentOpenPanel.files()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = URL(fileURLWithPath:entry.path).pathExtension.lowercased() == "pdf" ? [.pdf] : [UTType(exportedAs:"com.kongfolio.project")]
        panel.message = "选择这份文献现在所在的位置"
        DocumentOpenPanel.coordinator.present(panel,presentation:.separate) { [weak self] _,urls in
            guard let self,let url = urls.first else { return }
            guard let batch = self.readingBatch, batch.entries.contains(where:{$0.id == entry.id}) else { return }
            if let existing = batch.entry(url.path),existing.id != entry.id {
                self.openReadingBatchEntry(existing)
                return
            }
            if let old = self.tabs.compactMap(\.workspace).first(where:{$0.displayPath == entry.path && $0.count == 0}), !old.busy {
                self.close(old.id)
            }
            var replacement = entry
            replacement.path = url.path
            self.updateBatchEntry(entry.id) { $0.path = url.path }
            self.openReadingBatchEntry(replacement)
        }
    }
}
