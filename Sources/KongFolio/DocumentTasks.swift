import AppKit
import PDFKit
import Combine

struct DocumentTaskResult {
    var message: String
    var file: URL? = nil
}
struct DocumentTaskItem: Identifiable {
    enum State: String { case running = "处理中", cancelling = "正在取消", cancelled = "已取消", finished = "已完成", failed = "失败" }
    var id = UUID()
    var title: String
    var progress = 0.0
    var state = State.running
    var message = ""
    var file: URL?
    var created = Date()
    var active: Bool { state == .running || state == .cancelling }
}

/// Detached workers only receive immutable snapshots. The document in the reader stays editable.
@MainActor final class DocumentTaskQueue: ObservableObject {
    @Published private(set) var items: [DocumentTaskItem] = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var completions: [UUID: (DocumentTaskResult) -> Void] = [:]
    var running: Bool { items.contains(where: \.active) }
    var activeCount: Int { items.filter(\.active).count }
    @discardableResult func start(_ title: String, completion: ((DocumentTaskResult) -> Void)? = nil, operation: @escaping @Sendable (@escaping @Sendable (Double) -> Void) throws -> DocumentTaskResult) throws -> UUID {
        guard activeCount < 2 else { throw FolioError(message: "已有两个后台任务，请完成或取消其中一个后再开始") }
        let item = DocumentTaskItem(title: title), id = item.id
        items.insert(item, at: 0); completions[id] = completion
        if items.count > 20 { items.removeSubrange(20..<items.count) }
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try operation { value in Task { @MainActor [weak self] in self?.update(id) { $0.progress = min(1, max(0, value)) } } }
                await self?.complete(id, state: .finished, result: result)
            } catch is CancellationError { await self?.complete(id, state: .cancelled, result: DocumentTaskResult(message: "已取消，原件与已有输出保留")) }
            catch { await self?.complete(id, state: .failed, result: DocumentTaskResult(message: error.localizedDescription)) }
        }
        workers[id] = Task { await worker.value }
        cancellations[id] = { worker.cancel() }
        return id
    }
    private var cancellations: [UUID: () -> Void] = [:]
    private func update(_ id: UUID, _ change: (inout DocumentTaskItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }; change(&items[i])
    }
    private func complete(_ id: UUID, state: DocumentTaskItem.State, result: DocumentTaskResult) {
        update(id) { $0.state = state; $0.message = result.message; $0.file = result.file; if state == .finished { $0.progress = 1 } }
        let completion = completions.removeValue(forKey: id)
        workers[id] = nil; cancellations[id] = nil
        if state == .finished { completion?(result) }
    }
    func cancel(_ id: UUID) { guard items.first(where: { $0.id == id })?.active == true else { return }; update(id) { $0.state = .cancelling }; cancellations[id]?() }
    func cancelAll() { for item in items where item.active { cancel(item.id) } }
}

/// Commit only once, after cancellation and destination-conflict checks. Temporary output is never the original.
enum DocumentTaskOutput {
    static func sameFile(_ a: URL, _ b: URL) -> Bool { a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL }
    static func write(to destination: URL, expected: FileBaseline, generate: (URL) throws -> Void) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation(); try generate(staging); try Task.checkCancellation()
        try expected.writing(destination) { target in
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: target) }
        }
    }
}

extension Workspace {
    func startFlattenedForm(to destination: URL, queue: DocumentTaskQueue) throws {
        if let source = historySource, DocumentTaskOutput.sameFile(source, destination) { throw FolioError(message: "请将固定表单副本保存到其他位置") }
        let data = try pdfData(), expected = try FileBaseline.capture(destination)
        try queue.start("固定表单副本 · \(displayName)") { progress in
            try DocumentTaskOutput.write(to: destination, expected: expected) { staging in
                let document = try PDFDocument(data: data).unwrap("无法读取表单")
                let output = try PDFForms.flattened(document, progress: progress)
                try Task.checkCancellation()
                try output.dataRepresentation().unwrap("无法生成固定副本").write(to: staging)
            }
            return DocumentTaskResult(message: "固定副本已保存；原件保留", file: destination)
        }
    }
}
