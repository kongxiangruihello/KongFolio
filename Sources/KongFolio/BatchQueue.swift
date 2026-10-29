import AppKit
import CryptoKit
import PDFKit

struct BatchItem: Identifiable, Equatable, Codable {
    enum State: Equatable, Codable { case waiting, running, done(String), skipped(String), failed(String) }
    var id = UUID()
    var url: URL
    var state = State.waiting
    var progress = 0.0
    var attempts = 0
    var fingerprint: String?
    var completedPlan: String?
    var outputDigest: String?
}

struct BatchPlan: Codable, Equatable {
    var recipe: WorkRecipe
    var output: URL
    var replacements: [ReplacementRule]
    var key: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    }
}

@MainActor final class BatchQueue: ObservableObject {
    struct Saved: Codable { var items: [BatchItem]; var plan: BatchPlan? }
    struct Completion { var note: String; var fingerprint: String; var skipped: Bool; var outputDigest: String }
    @Published var items: [BatchItem] = []
    @Published var running = false
    @Published var fileProgress = 0.0
    @Published var summary = ""
    @Published private(set) var plan: BatchPlan?
    @Published private(set) var stopping = false
    private var task: Task<Void, Never>?
    private var worker: Task<Completion, Error>?
    let storage: URL?
    var stateURL: URL? { storage?.appendingPathComponent("BatchQueue.json") }

    init(storage: URL? = nil) {
        self.storage = storage
        if let url = stateURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
                items = saved.items.map { var i = $0; if case .running = i.state { i.state = .waiting; i.progress = 0 }; return i }
                plan = saved.plan
                if !items.isEmpty { summary = "已恢复任务队列，可继续未完成项或重试失败项。" }
            } catch { summary = "队列记录无法读取，文件已保留：\(error.localizedDescription)" }
        }
    }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    var completedCount: Int { items.filter { if case .done = $0.state { return true }; if case .skipped = $0.state { return true }; return false }.count }
    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { total, i in
            switch i.state { case .done, .skipped, .failed: return total + 1; case .running: return total + i.progress; case .waiting: return total }
        } / Double(items.count)
    }
    static func pdfFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return names.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    nonisolated static func outputs(for input: URL, in folder: URL, recipe: WorkRecipe) -> (pdf: URL?, word: URL?, chapters: URL?) {
        let stem = input.deletingPathExtension().lastPathComponent
        return (recipe.writePDF ? folder.appendingPathComponent(stem + ".pdf") : nil, recipe.word != nil ? folder.appendingPathComponent(stem + ".docx") : nil, recipe.splitChapters ? folder.appendingPathComponent(stem + "-章节", isDirectory: true) : nil)
    }
    func persist() throws {
        guard let stateURL else { return }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Saved(items: items, plan: plan)).write(to: stateURL, options: .atomic)
    }
    private func remember() { do { try persist() } catch { summary = "队列保存失败：\(error.localizedDescription)" } }
    func load(_ folder: URL) {
        guard !running else { return }
        items = Self.pdfFiles(in: folder).map { BatchItem(url: $0) }; plan = nil
        summary = items.isEmpty ? "这个文件夹里没有 PDF。" : "找到 \(items.count) 个 PDF。"; remember()
    }
    func add(_ urls: [URL]) {
        guard !running else { return }
        var added = 0, rejected = 0
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "pdf" {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if items.contains(where: { $0.url.standardizedFileURL.resolvingSymlinksInPath() == canonical }) { continue }
            if items.contains(where: { $0.url.deletingPathExtension().lastPathComponent.lowercased() == url.deletingPathExtension().lastPathComponent.lowercased() }) { rejected += 1; continue }
            items.append(BatchItem(url: url)); added += 1
        }
        summary = "加入 \(added) 个 PDF。" + (rejected > 0 ? "\(rejected) 个文件与队列文件同名，请改名后再加入。" : ""); remember()
    }
    func clear() { guard !running else { return }; clearCheckpoints();items = []; plan = nil; summary = "队列已清空，输出文件保留。"; remember() }
    func clearCheckpoints() {
        guard !running,let storage else { return }
        do { let url=storage.appendingPathComponent("BatchPages");if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
        catch { summary="续跑缓存清理失败：\(error.localizedDescription)" }
    }
    func resume() { if let plan { start(recipe: plan.recipe, output: plan.output, replacements: plan.replacements, mode: .unfinished) } }
    func retryFailed() { if let plan { start(recipe: plan.recipe, output: plan.output, replacements: plan.replacements, mode: .failed) } }
    func retryItem(_ id: UUID) {
        if let plan { start(recipe: plan.recipe, output: plan.output, replacements: plan.replacements, mode: .one(id)) }
    }
    enum RunMode { case all, unfinished, failed, one(UUID) }
    func start(recipe: WorkRecipe, output: URL, replacements: [ReplacementRule], mode: RunMode = .all) {
        guard !running, !items.isEmpty else { return }
        guard !recipe.isEmpty, recipe.writePDF || recipe.word != nil || recipe.splitChapters else { summary = "配方没有输出步骤，请启用 PDF、Word 或章节输出。"; return }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        guard !items.contains(where: { $0.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == destination }) else {
            summary = "输出文件夹不能和任意原文件夹相同，以免覆盖原件。"; return
        }
        let chosen = items.indices.filter { index in
            switch mode { case .one(let id): return items[index].id == id; case .all: return true; case .unfinished: if case .waiting = items[index].state { return true }; return false; case .failed: if case .failed = items[index].state { return true }; return false }
        }
        guard !chosen.isEmpty else { summary = "没有需要执行的项目。"; return }
        let plan = BatchPlan(recipe: recipe, output: output, replacements: replacements)
        self.plan = plan
        for i in chosen { items[i].state = .waiting; items[i].progress = 0 }
        // A durable checkpoint is required before any output is written.
        do { try persist() } catch { summary = "无法保存队列，任务未开始：\(error.localizedDescription)"; return }
        running = true; stopping = false; summary = ""
        task = Task { [self] in
            var done = 0, skipped = 0, failed = 0
            for index in chosen {
                if Task.isCancelled { break }
                let item = items[index]
                items[index].state = .running; items[index].attempts += 1; fileProgress = 0; remember()
                let attempt = items[index].attempts
                let checkpointRoot=storage?.appendingPathComponent("BatchPages",isDirectory:true).appendingPathComponent(item.id.uuidString,isDirectory:true)
                let worker = Task.detached(priority: .userInitiated) {
                    try Self.process(item, plan: plan, checkpointRoot:checkpointRoot) { value in
                        Task { @MainActor in
                            guard self.running, self.items.indices.contains(index), self.items[index].id == item.id, self.items[index].attempts == attempt, case .running = self.items[index].state else { return }
                            self.fileProgress = max(self.fileProgress, value)
                            self.items[index].progress = self.fileProgress
                        }
                    }
                }
                self.worker = worker
                do {
                    let result = try await worker.value
                    items[index].outputDigest = result.outputDigest; items[index].fingerprint = result.fingerprint; items[index].completedPlan = plan.key; items[index].progress = 1
                    if result.skipped { items[index].state = .skipped(result.note); skipped += 1 }
                    else { items[index].state = .done(result.note); done += 1 }
                } catch is CancellationError { items[index].state = .waiting; items[index].progress = 0 }
                catch { items[index].state = .failed(error.localizedDescription); failed += 1 }
                self.worker = nil; remember()
            }
            running = false; stopping = false; fileProgress = 0
            summary = (Task.isCancelled ? "已暂停：" : "完成：") + "处理 \(done) 个，跳过 \(skipped) 个，失败 \(failed) 个。"
            remember(); task = nil
        }
    }
    func cancel() { guard running else { return }; stopping = true; task?.cancel(); worker?.cancel() }

    nonisolated static func process(_ item: BatchItem, plan: BatchPlan, checkpointRoot: URL? = nil, progress: @escaping @Sendable (Double) -> Void) throws -> Completion {
        try Task.checkCancellation()
        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = outputs(for: item.url, in: plan.output, recipe: plan.recipe)
        let wanted = [target.pdf, target.word, target.chapters].compactMap { $0 }
        let existing = wanted.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            if existing.count == wanted.count, item.fingerprint == fingerprint, item.completedPlan == plan.key {
                let digest = try digestOutputs(wanted)
                guard item.outputDigest == digest else { throw FolioError(message: "已有结果被修改，未跳过或覆盖，请选择新输出文件夹。") }
                return Completion(note: "本队列结果已校验", fingerprint: fingerprint, skipped: true, outputDigest: digest)
            }
            throw FolioError(message: "输出已存在或原件/配方已变化，请选择新的输出文件夹；未覆盖任何已有结果。")
        }
        try FileManager.default.createDirectory(at: plan.output, withIntermediateDirectories: true)
        let staging = plan.output.appendingPathComponent(".KongFolio-\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = outputs(for: item.url, in: staging, recipe: plan.recipe)
        let result = try BatchPipeline.process(data, recipe: plan.recipe, replacements: plan.replacements, wordURL: staged.word, checkpointRoot:checkpointRoot, progress: progress)
        if let pdf = result.pdf, let url = staged.pdf { try pdf.write(to: url) }
        if let folder = staged.chapters { try placeFolder(result.chapters, at: folder) }
        let digest = try digestOutputs([staged.pdf, staged.word, staged.chapters].compactMap { $0 })
        try Task.checkCancellation()
        var committed: [URL] = []
        do {
            for (source, destination) in zip([staged.pdf, staged.word, staged.chapters], [target.pdf, target.word, target.chapters]) {
                if let source, let destination { try FileManager.default.moveItem(at: source, to: destination); committed.append(destination) }
            }
        } catch {
            // Only paths created by this commit are rolled back; pre-existing files are never replaced.
            for url in committed { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        if let checkpointRoot { try? FileManager.default.removeItem(at:checkpointRoot) }
        return Completion(note: "\(result.pages) 页" + (result.recognized > 0 ? "，识别 \(result.recognized) 页" : "") + (result.resumed > 0 ? "，续跑复用 \(result.resumed) 页" : ""), fingerprint: fingerprint, skipped: false, outputDigest: digest)
    }
    nonisolated static func digestOutputs(_ urls: [URL]) throws -> String {
        var digest = SHA256()
        for url in urls {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { throw FolioError(message: "缺少处理结果：\(url.lastPathComponent)") }
            let files: [URL]
            if directory.boolValue {
                files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !files.isEmpty else { throw FolioError(message: "章节输出为空") }
            } else { files = [url] }
            for file in files {
                try Task.checkCancellation()
                digest.update(data: Data((url.lastPathComponent + "/" + file.lastPathComponent).utf8))
                digest.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func place(_ data: Data, at url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging); try move(staging, to: url)
    }
    nonisolated static func placeFolder(_ files: [(name: String, data: Data)], at folder: URL) throws {
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in files { try file.data.write(to: staging.appendingPathComponent(file.name)) }
        try move(staging, to: folder)
    }
    nonisolated static func move(_ staged: URL, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: url) }
    }
}

extension BatchQueue {
    func stagePlan(_ value: BatchPlan) { guard !running else { return }; plan = value; summary = "已带入试做配方，请核对后开始"; try? persist() }
}
