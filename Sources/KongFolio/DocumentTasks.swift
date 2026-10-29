import AppKit
import PDFKit
import Combine

struct DocumentTaskResult {
    var message: String
    var file: URL? = nil
}
struct DocumentTaskItem: Codable, Identifiable {
    enum State: String, Codable { case queued = "等待重试", paused = "已暂停", pausing = "正在暂停"; case running = "处理中", cancelling = "正在取消", cancelled = "已取消", finished = "已完成", failed = "失败" }
    var id = UUID()
    var title: String
    var progress = 0.0
    var state = State.running
    var message = ""
    var file: URL?
    var created = Date()
    var active: Bool { state == .running || state == .cancelling || state == .pausing }
}

/// Detached workers only receive immutable snapshots. The document in the reader stays editable.
@MainActor final class DocumentTaskQueue: ObservableObject {
    @Published private(set) var items: [DocumentTaskItem] = []
    let storage: URL?
    private let transientStorage = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolioTasks-" + UUID().uuidString, isDirectory: true)
    @Published private(set) var persistenceMessage = ""
    private var specs: [UUID: PersistentDocumentTask] = [:]
    private var pausing = Set<UUID>()
    private var retryPending: [UUID] = []
    var didFinishPersistent: ((DocumentTaskResult) -> Void)?
    private var lastSavedProgress: [UUID: Double] = [:]
    private var unreadableIndex = false
    init(storage: URL? = nil) {
        self.storage = storage
        guard let storage else { return }
        let index = storage.appendingPathComponent("DocumentTasks/index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        do {
            let value = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: index))
            guard Set(value.items.map(\.id)).count == value.items.count, value.items.count <= 1000 else { throw FolioError(message: "任务记录无效") }
            specs = value.specs
            items = value.items.map { item in var copy = item; if copy.active || copy.state == .queued { copy.state = .paused; copy.message = "上次处理已中断，可继续；原件和已有输出保留" }; return copy }
        } catch { unreadableIndex = true; persistenceMessage = "任务记录无法读取，原记录保留：" + error.localizedDescription }
    }
    private struct Archive: Codable { var items: [DocumentTaskItem]; var specs: [UUID: PersistentDocumentTask] }
    @discardableResult private func persist() -> Bool {
        guard let storage else { return true }
        do {
            let folder = storage.appendingPathComponent("DocumentTasks", isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if unreadableIndex {
                let index=folder.appendingPathComponent("index.json")
                if FileManager.default.fileExists(atPath:index.path) { try FileManager.default.copyItem(at:index,to:folder.appendingPathComponent("unreadable-"+UUID().uuidString+".json")) }
                unreadableIndex=false
            }
            let saved = items.filter { specs[$0.id] != nil }
            try JSONEncoder().encode(Archive(items: saved, specs: specs.filter { key, _ in saved.contains { $0.id == key } })).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
            return true
        } catch { persistenceMessage = "任务进度未能保存：" + error.localizedDescription; return false }
    }
    func canPause(_ id: UUID) -> Bool { specs[id] != nil && items.first(where: { $0.id == id })?.state == .running }
    func canResume(_ id: UUID) -> Bool { specs[id] != nil && items.first(where: { $0.id == id }).map { !$0.active && $0.state != .finished && $0.state != .queued } == true }
    func taskFolder(_ id: UUID) throws -> URL { (storage ?? transientStorage).appendingPathComponent("DocumentTasks/" + id.uuidString, isDirectory: true) }
    @discardableResult func startPersistent(_ title: String, source: Data, spec: PersistentDocumentTask, completion: ((DocumentTaskResult) -> Void)? = nil) throws -> UUID {
        guard activeCount < 2 else { throw FolioError(message: "已有两个后台任务，请稍后重试") }
        guard items.count < 1000 else { throw FolioError(message: "保存的任务过多，请先完成已有任务") }
        let item = DocumentTaskItem(title: title), id = item.id, folder = try taskFolder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try source.write(to: folder.appendingPathComponent("source.pdf"), options: .atomic)
        var prepared = spec; prepared.sourceDigest = OCRPageCache.digest(source)
        let value = prepared
        items.insert(item, at: 0); specs[id] = value; completions[id] = completion
        while items.count > 50, let oldest = items.lastIndex(where: { $0.state == .finished }) { let old = items.remove(at:oldest); specs[old.id]=nil }
        guard persist() else { items.removeAll { $0.id == id }; specs[id]=nil;completions[id]=nil;throw FolioError(message:persistenceMessage) }
        launch(id) { progress in try value.run(source: source, folder: folder, progress: progress) }
        return id
    }
    func resume(_ id: UUID) throws {
        guard canResume(id) || retryPending.contains(id), activeCount < 2, let spec = specs[id] else { throw FolioError(message: "任务不可继续，或已有两个任务在运行") }
        let folder = try taskFolder(id)
        retryPending.removeAll { $0 == id }; pausing.remove(id); update(id) { $0.state = .running; $0.message = "正在核对原文件并读取检查点…" }; persist()
        launch(id) { progress in try spec.run(source: Data(contentsOf: folder.appendingPathComponent("source.pdf")), folder: folder, progress: progress) }
    }
    func retryFailed() {
        let ids = items.filter { $0.state == .failed && canResume($0.id) }.map(\.id)
        retryPending.append(contentsOf: ids)
        for id in ids { update(id) { $0.state = .queued; $0.message = "等待空闲后重试" } }
        persist(); drainRetries()
    }
    private func drainRetries() {
        while activeCount < 2, let id = retryPending.first {
            do { try resume(id) }
            catch { retryPending.removeAll { $0 == id }; update(id) { $0.state = .failed; $0.message = error.localizedDescription }; persist() }
        }
    }
    private func pausePendingRetries() {
        for id in retryPending { update(id) { $0.state = .paused; $0.message = "等待任务已暂停，可手动继续" } }
        retryPending.removeAll(); persist()
    }
    func pause(_ id: UUID) { guard specs[id] != nil, items.first(where: { $0.id == id })?.active == true else { return }; pausing.insert(id); update(id) { $0.state = .pausing }; persist(); cancellations[id]?() }
    func pauseAll() { pausePendingRetries(); for item in items where item.active { if specs[item.id] != nil { pause(item.id) } else { cancel(item.id) } } }
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var completions: [UUID: (DocumentTaskResult) -> Void] = [:]
    var running: Bool { items.contains { $0.active || $0.state == .queued } }
    var activeCount: Int { items.filter(\.active).count }
    @discardableResult func start(_ title: String, completion: ((DocumentTaskResult) -> Void)? = nil, operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) throws -> DocumentTaskResult) throws -> UUID {
        guard activeCount < 2 else { throw FolioError(message: "已有两个后台任务，请完成或取消其中一个后再开始") }
        let item = DocumentTaskItem(title: title), id = item.id
        items.insert(item, at: 0); completions[id] = completion
        while items.count > 20, let oldest = items.lastIndex(where: { !$0.active && ($0.state == .finished || specs[$0.id] == nil) }) { items.remove(at: oldest) }
        persist()
        launch(id, operation: operation)
        return id
    }
    private func launch(_ id: UUID, operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) throws -> DocumentTaskResult) {
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try operation { value in Task { @MainActor [weak self] in self?.reportProgress(id,value:value) } }
                await self?.complete(id, state: .finished, result: result)
            } catch is CancellationError { await self?.complete(id, state: .cancelled, result: DocumentTaskResult(message: "已取消，原件与已有输出保留")) }
            catch { await self?.complete(id, state: .failed, result: DocumentTaskResult(message: error.localizedDescription)) }
        }
        workers[id] = Task { await worker.value }
        cancellations[id] = { worker.cancel() }
    }
    private func reportProgress(_ id: UUID, value: Double) {
        guard items.first(where: { $0.id == id })?.active == true else { return }
        update(id) { $0.progress = min(1,max(0,value)) }
        if value >= 1 || value - (lastSavedProgress[id] ?? -1) >= 0.02 { lastSavedProgress[id]=value;persist() }
    }
    private var cancellations: [UUID: () -> Void] = [:]
    private func update(_ id: UUID, _ change: (inout DocumentTaskItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }; change(&items[i])
    }
    private func complete(_ id: UUID, state: DocumentTaskItem.State, result: DocumentTaskResult) {
        let state = state == .cancelled && pausing.remove(id) != nil ? DocumentTaskItem.State.paused : state
        update(id) { $0.state = state; $0.message = result.message; $0.file = result.file; if state == .finished { $0.progress = 1 }; if state == .paused { $0.message = "进度已保存，可继续处理" } }
        let completion = completions.removeValue(forKey: id)
        workers[id] = nil; cancellations[id] = nil
        persist()
        if state == .finished {
            if specs[id] != nil, let folder = try? taskFolder(id) { try? FileManager.default.removeItem(at:folder) }
            if specs[id] != nil { didFinishPersistent?(result) }
            completion?(result)
        }
        drainRetries()
    }
    func cancel(_ id: UUID) { if retryPending.contains(id) { retryPending.removeAll { $0 == id }; update(id) { $0.state = .cancelled; $0.message = "已取消等待，已有进度保留" }; persist(); return }; guard items.first(where: { $0.id == id })?.active == true else { return }; pausing.remove(id); update(id) { $0.state = .cancelling }; persist(); cancellations[id]?() }
    func cancelAll() { for item in items where item.active || item.state == .queued { cancel(item.id) } }
}

/// Commit only once, after cancellation and destination-conflict checks. Temporary output is never the original.
enum DocumentTaskOutput {
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL { return true }
        // Hard links are aliases too; comparing only path strings would allow overwriting the open source.
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: keys), let y = try? b.resourceValues(forKeys: keys),
              let xi = x.fileResourceIdentifier as? NSObject, let yi = y.fileResourceIdentifier as? NSObject,
              let xv = x.volumeIdentifier as? NSObject, let yv = y.volumeIdentifier as? NSObject else { return false }
        return xi == yi && xv == yv
    }
    static func write(to destination: URL, expected: FileBaseline, protectedSource: URL? = nil, generate: (URL) throws -> Void) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        if let protectedSource, sameFile(destination, protectedSource) { throw FolioError(message: "导出副本不能覆盖原件，请选择其他位置") }
        try Task.checkCancellation(); try generate(staging); try Task.checkCancellation()
        do {
            try expected.writing(destination) { target in
                try Task.checkCancellation()
                if let protectedSource, sameFile(target, protectedSource) || sameFile(destination, protectedSource) { throw FolioError(message: "导出位置已指向原件，未覆盖，请选择其他位置") }
                if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
                else { try FileManager.default.moveItem(at: staging, to: target) }
            }
        } catch is FileConflict {
            let copy = destination.deletingLastPathComponent().appendingPathComponent(destination.deletingPathExtension().lastPathComponent + "-导出副本-" + UUID().uuidString.prefix(8) + "." + destination.pathExtension)
            try FileManager.default.moveItem(at: staging, to: copy)
            throw ExportOutputConflict(copy: copy)
        }
    }
}

extension Workspace {
    func startFlattenedForm(to destination: URL, queue: DocumentTaskQueue) throws {
        if let source = historySource, DocumentTaskOutput.sameFile(source, destination) { throw FolioError(message: "请将固定表单副本保存到其他位置") }
        let data = try pdfData(), expected = try FileBaseline.capture(destination)
        try queue.startPersistent("固定表单副本 · \(displayName)", source: data, spec: PersistentDocumentTask(kind: .flatten, destination: destination, expected: expected, sourceBaseline: fileBaseline))
    }
}

struct ExportOutputConflict: LocalizedError {
    let copy: URL
    var errorDescription: String? { "导出位置已被其他软件修改，原文件保持不变；生成结果已保存为：" + copy.path }
}
