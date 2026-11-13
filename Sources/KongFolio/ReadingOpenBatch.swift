import AppKit
import UniformTypeIdentifiers

struct ReadingOpenBatch: Codable, Equatable, Identifiable {
    static let key = "KongFolio.lastReadingBatch"
    static let historyKey = "KongFolio.readingBatchHistory"
    static let historyLimit = 10

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
    var created: Date? = nil
    var id: UUID? { entries.first?.id }
    var finishedCount: Int { entries.filter { $0.status == .finished }.count }
    var pendingCount: Int { entries.filter { $0.status == .pending }.count }
    var next: Entry? {
        entries.first{$0.id == current && $0.status == .pending} ?? entries.first{$0.status == .pending}
    }
    static func load(_ defaults:UserDefaults) -> Self? {
        loadHistory(defaults).first
    }
    static func loadHistory(_ defaults:UserDefaults) -> [Self] {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey:historyKey),let history = try? decoder.decode([Self].self,from:data) {
            return Array(history.filter { !$0.entries.isEmpty }.prefix(historyLimit))
        }
        if let data = defaults.data(forKey:key),let legacy = try? decoder.decode(Self.self,from:data),!legacy.entries.isEmpty {
            return [legacy]
        }
        return []
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
    var readingBatch: ReadingOpenBatch? {
        readingBatches.first { $0.id == selectedReadingBatchID } ?? readingBatches.first
    }

    func readingBatchEntry(_ path:String?) -> ReadingOpenBatch.Entry? {
        readingBatch?.entry(path) ?? readingBatches.lazy.compactMap { $0.entry(path) }.first
    }

    func readingBatchEntry(for workspace:Workspace) -> ReadingOpenBatch.Entry? {
        guard let id = workspace.readingBatchEntryID else { return readingBatchEntry(workspace.displayPath) }
        return readingBatches.lazy.flatMap(\.entries).first { $0.id == id }
    }

    func readingBatchPosition(_ path:String) -> ViewPosition? {
        readingBatch?.entry(path)?.position ?? readingBatches.lazy.compactMap { $0.entry(path)?.position }.first
    }

    private func saveReadingBatches(_ batches:[ReadingOpenBatch]) {
        guard readingBatches != batches else { return }
        readingBatches = batches
        if let data = try? JSONEncoder().encode(batches) {
            readingDefaults.set(data,forKey:ReadingOpenBatch.historyKey)
        }
    }

    func startReadingBatch(_ urls:[URL]) {
        var seen = Set<String>()
        let entries = urls.filter { url in
            url.isFileURL && ["pdf","kongfolio"].contains(url.pathExtension.lowercased()) &&
                seen.insert(ReadingBookIdentity.key(url.path)).inserted
        }.map{ReadingOpenBatch.Entry(id:UUID(),path:$0.path)}
        guard entries.count > 1 else { return }
        let batch = ReadingOpenBatch(entries:entries,current:entries.first?.id,created:Date())
        selectedReadingBatchID = batch.id
        saveReadingBatches(Array(([batch]+readingBatches).prefix(ReadingOpenBatch.historyLimit)))
    }

    func updateBatchEntry(_ id:UUID,_ edit:(inout ReadingOpenBatch.Entry)->Void) {
        guard let batchIndex = readingBatches.firstIndex(where:{$0.entries.contains(where:{$0.id == id})}),
              let index = readingBatches[batchIndex].entries.firstIndex(where:{$0.id == id}) else { return }
        var batches = readingBatches
        edit(&batches[batchIndex].entries[index])
        saveReadingBatches(batches)
    }

    func trackBatchSelection(_ workspace:Workspace?) {
        guard let workspace,let entry = readingBatchEntry(for:workspace),entry.status == .pending,
              let index = readingBatches.firstIndex(where:{$0.entries.contains(where:{$0.id == entry.id})}) else { return }
        var batches = readingBatches
        batches[index].current = entry.id
        saveReadingBatches(batches)
    }

    func captureBatchPosition(_ workspace:Workspace) {
        guard workspace.count > 0,!workspace.browsingReadingReference,
              let entry = readingBatchEntry(for:workspace) else { return }
        let position = workspace.currentViewPosition()
        updateBatchEntry(entry.id) { $0.position = position }
    }

    func recordBatchLoad(_ workspace:Workspace,error:Error? = nil) {
        guard let entry = readingBatchEntry(for:workspace),entry.status != .skipped else { return }
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
        guard let batch = readingBatches.first(where:{$0.entries.contains(where:{$0.id == entry.id})}) else { return }
        selectedReadingBatchID = batch.id
        if entry.status != .finished { updateBatchEntry(entry.id) { $0.status = .pending; $0.message = nil } }
        openEach([URL(fileURLWithPath:entry.path)],startBatch:false)
    }

    func nextAfterFinishing(_ workspace: Workspace) -> ReadingOpenBatch.Entry? {
        guard workspace.count > 0, !workspace.busy, !workspace.browsingReadingReference,
              let entry = readingBatchEntry(for:workspace), entry.status == .pending,
              let batch = readingBatches.first(where:{ $0.entries.contains(where:{ $0.id == entry.id }) }) else { return nil }
        return batch.pendingAfterFinishing(entry.id)
    }

    func finishReadingAndOpenNext(_ workspace: Workspace) async {
        guard activeWorkspace === workspace, !workspace.closingInProgress, let next = nextAfterFinishing(workspace),
              let entry = readingBatchEntry(for:workspace) else { return }
        guard await workspace.finishPendingSave(), activeWorkspace === workspace,
              !workspace.busy, !workspace.dirty, !workspace.saving,
              readingBatchEntry(for:workspace)?.id == entry.id,
              nextAfterFinishing(workspace)?.id == next.id else { return }
        let position = workspace.currentViewPosition()
        workspace.saveReadingRecord(capture:false)
        updateBatchEntry(entry.id) {
            $0.position = position
            $0.status = .finished
        }
        openReadingBatchEntry(next)
    }

    func skipReadingBatchEntry(_ entry:ReadingOpenBatch.Entry) {
        updateBatchEntry(entry.id) { $0.status = .skipped }
        guard let workspace = tabs.compactMap(\.workspace).first(where:{ readingBatchEntry(for:$0)?.id == entry.id }) else { return }
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
            guard let batch = self.readingBatches.first(where:{$0.entries.contains(where:{$0.id == entry.id})}) else { return }
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
