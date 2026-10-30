import AppKit
#if canImport(KongFolioUpdateKit)
import KongFolioUpdateKit
#endif

@MainActor final class AppUpdateController: ObservableObject {
    enum Phase: Equatable { case idle, checking, available, current, downloading, verifying, ready, opened, cancelled, failed, preparingInstall, installing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var release: AppUpdateRelease?
    @Published private(set) var progress = AppUpdateProgress(received: 0, expected: 0)
    @Published private(set) var message = "点击“检查更新”获取最新正式版本。"
    @Published private(set) var file: URL?
    @Published private(set) var installationResult: UpdateInstallResult?
    let current: AppUpdateVersion
    private let transport: any AppUpdateTransport
    private let folder: URL
    private var generation = UUID()
    private var job: Task<Void, Never>?
    init(current: AppUpdateVersion, folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-Updates", isDirectory: true), transport: any AppUpdateTransport = AppUpdateNetwork()) { self.current = current; self.folder = folder; self.transport = transport }
    var busy: Bool { [.checking, .downloading, .verifying, .preparingInstall, .installing].contains(phase) }
    var canDownload: Bool { release.map { $0.version > current } == true && !busy && file == nil }
    var canInstall: Bool { release.map { $0.version > current } == true && !busy && file != nil }
    func loadInstallationResult(_ url: URL) { if let data = try? Data(contentsOf: url), data.count < 128*1024 { installationResult = try? JSONDecoder().decode(UpdateInstallResult.self, from: data) } }
    func check() {
        guard !busy else { return }
        job?.cancel(); generation = UUID(); let token = generation
        phase = .checking; message = "正在检查更新…"
        job = Task { [weak self, transport] in
            do {
                let latest = try await transport.latest(); try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                if self.release?.asset != latest.asset || self.release?.sha256 != latest.sha256 || self.release?.size != latest.size { self.removeDownloadedFile() }
                self.release = latest
                if latest.version > self.current { self.phase = self.file == nil ? .available : .ready; self.message = "发现新版本 \(latest.version)" }
                else { self.phase = .current; self.message = "已是最新版本（当前 \(self.current)）" }
            } catch { self?.complete(error, token: token) }
        }
    }
    func download() {
        guard canDownload, let release else { return }
        job?.cancel(); generation = UUID(); let token = generation
        phase = .downloading; progress = AppUpdateProgress(received: 0, expected: release.size); message = "正在下载安装包…"
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true), file = directory.appendingPathComponent(release.filename)
        let report: @MainActor @Sendable (AppUpdateProgress) -> Void = { [weak self] value in
            guard let self, self.generation == token, self.phase == .downloading, value.received >= self.progress.received else { return }
            self.progress = value
        }
        job = Task { [weak self, transport] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await transport.download(release, to: file) { value in Task { @MainActor in report(value) } }
                try Task.checkCancellation()
                guard let self, self.generation == token else { try? FileManager.default.removeItem(at: directory); return }
                self.phase = .verifying; self.message = "下载完成，正在校验安装包…"
                let validation = Task.detached(priority: .utility) { try AppUpdateValidation.verify(file, release: release) }
                try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
                try Task.checkCancellation()
                guard self.generation == token else { try? FileManager.default.removeItem(at: directory); return }
                self.file = file; self.progress = AppUpdateProgress(received: release.size, expected: release.size)
                self.phase = .ready; self.message = "安装包已下载并通过校验，可以在线安装并重新打开。"
            } catch {
                try? FileManager.default.removeItem(at: directory)
                self?.complete(error, token: token)
            }
        }
    }
    func cancel() {
        guard busy, phase != .installing else { return }
        generation = UUID(); job?.cancel(); job = nil
        phase = .cancelled; message = "已取消，可重新检查或下载。"
    }
    func install(target: URL, expectedIdentifier: String, resultURL: URL, parentLaunchDate: Date?, handoff: @escaping @MainActor (UpdateInstallJob, @escaping (Error?) -> Void) throws -> Void) {
        guard canInstall, let file, let release else { return }
        generation = UUID(); let token = generation; phase = .preparingInstall; message = "正在准备在线安装，阅读记录将在退出前保存…"
        job = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) { try AppUpdateInstaller.prepare(file, release: release, target: target, expectedIdentifier: expectedIdentifier, resultURL: resultURL, parentLaunchDate: parentLaunchDate) }
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }); try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.phase = .installing; self.message = "正在保存阅读记录并交给安装组件，请稍候…"
                try handoff(prepared) { [weak self] error in
                    guard let self, self.generation == token, let error else { return }
                    self.phase = .ready; self.message = error.localizedDescription
                }
            } catch { self?.complete(error, token: token) }
        }
    }
    func openInstaller() {
        guard let file, let release, !busy else { return }
        generation = UUID(); let token = generation; phase = .verifying; message = "正在核对安装包…"
        job = Task { [weak self] in
            do {
                let validation = Task.detached(priority: .utility) { try AppUpdateValidation.verify(file, release: release) }
                try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() }); try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                guard NSWorkspace.shared.open(file) else { throw FolioError(message: "无法打开安装包，请在访达中打开") }
                self.phase = .opened; self.message = "已打开安装包。退出 KongFolio 后，将新版本拖到“应用程序”完成安装，再重新打开。"
            } catch {
                if !FolioCancellation.matches(error), self?.generation == token { self?.removeDownloadedFile() }
                self?.complete(error, token: token)
            }
        }
    }
    private func complete(_ error: Error, token: UUID) {
        guard generation == token else { return }
        if FolioCancellation.matches(error) { phase = .cancelled; message = "已取消，可重新检查或下载。" }
        else { phase = .failed; message = "更新未完成："+error.localizedDescription }
        if file != nil, !FileManager.default.fileExists(atPath: file!.path) { file = nil }
    }
    private func removeDownloadedFile() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil
    }
}
