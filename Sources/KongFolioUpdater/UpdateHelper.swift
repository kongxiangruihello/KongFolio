import AppKit
import KongFolioUpdateKit

@MainActor private final class UpdateLaunchReply {
    var finished = false
    var application: NSRunningApplication?
    var error: Error?
}

@MainActor final class UpdateHelperDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let job: UpdateInstallJob
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "等待阅读记录保存和原程序退出…")
    private let bar = NSProgressIndicator()
    private let done = NSButton(title: "完成", target: nil, action: nil)
    private let backupButton = NSButton(title: "显示保留的上一版本", target: nil, action: nil)
    private var busy = true
    private var transaction: UpdateInstalledTransaction?
    private var launched: NSRunningApplication?
    init(job: UpdateInstallJob) { self.job = job }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 235), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "KongFolio 正在更新"; window.delegate = self; window.isReleasedWhenClosed = false; self.window = window
        let title = NSTextField(labelWithString: "正在安装 KongFolio "+job.incoming.version); title.font = .boldSystemFont(ofSize: 18)
        bar.minValue = 0; bar.maxValue = 4; bar.isIndeterminate = false; bar.style = .bar
        done.target = self; done.action = #selector(close); done.isHidden = true
        backupButton.target = self; backupButton.action = #selector(revealBackup); backupButton.isHidden = true
        let actions = NSStackView(views: [backupButton, done]); actions.orientation = .horizontal; actions.spacing = 16
        let stack = NSStackView(views: [title, status, bar, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), bar.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do { try job.signal(job.readyFile) } catch { fail(error); return }
        Task { await update() }
    }
    private func update() async {
        do {
            for _ in 0..<240 {
                if job.signalled(job.work.appendingPathComponent("abort")) { throw UpdateInstallFailure("安装已取消，原版本保持可用") }
                guard let parent = NSRunningApplication(processIdentifier: job.parentPID), !parent.isTerminated else { break }
                if let date = job.parentLaunchDate, let current = parent.launchDate, abs(date.timeIntervalSince(current)) > 1 { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !runningTarget() else { throw UpdateInstallFailure("原程序仍在运行，已停止安装，请退出后重试") }
            let report: @MainActor @Sendable (Int, String) -> Void = { [weak self] step, text in self?.bar.doubleValue = Double(step); self?.status.stringValue = text }
            let job = job
            let transaction = try await Task.detached(priority: .userInitiated) { try UpdateInstallCore.install(job) { step, text in Task { @MainActor in report(step, text) } } }.value
            self.transaction = transaction
            launched = try await launch(job.target, arguments: ["--kongfolio-update-job", job.file.path])
            for _ in 0..<240 {
                if job.signalled(job.startedFile) { break }
                if launched?.isTerminated == true { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard job.signalled(job.startedFile), launched?.isTerminated != true else { throw UpdateInstallFailure("新版未能完成启动，正在还原上一版本…") }
            UpdateInstallCore.finish(transaction)
            try? UpdateInstallResult(job: job, backup: transaction.backup, status: "installed", message: "已在线安装并重新打开 "+job.incoming.version).write(to: job.resultURL)
            bar.doubleValue = 4; status.stringValue = "更新完成，已重新打开。上一版本已保留。"; busy = false
            try? await Task.sleep(nanoseconds: 1_500_000_000); NSApp.terminate(nil)
        } catch {
            if let transaction {
                let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == job.target.standardizedFileURL.resolvingSymlinksInPath() }
                if !applications.isEmpty {
                    for application in applications { _ = application.terminate() }
                    for _ in 0..<40 { if applications.allSatisfy(\.isTerminated) { break }; try? await Task.sleep(nanoseconds: 250_000_000) }
                    guard applications.allSatisfy(\.isTerminated) else { UpdateInstallCore.finish(transaction); fail(UpdateInstallFailure("新版仍在运行，已停止自动还原；上一版本备份已保留")); return }
                }
                do {
                    try await Task.detached(priority: .userInitiated) { try UpdateInstallCore.rollback(transaction) }.value
                    UpdateInstallCore.finish(transaction)
                    try? UpdateInstallResult(job: job, backup: nil, status: "rolledBack", message: "新版启动失败，已还原上一版本").write(to: job.resultURL)
                    _ = try? await launch(job.target)
                    self.transaction = nil
                    fail(UpdateInstallFailure("新版启动失败，已还原并重新打开上一版本。可稍后重试。"), status: "rolledBack")
                } catch { UpdateInstallCore.finish(transaction); fail(error) }
            } else {
                if !runningTarget(), (try? UpdateInstallCore.inspect(job.target)) == job.original { _ = try? await launch(job.target) }
                fail(error)
            }
        }
    }
    private func launch(_ url: URL, arguments: [String] = []) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.createsNewApplicationInstance = true; configuration.addsToRecentItems = false; configuration.arguments = arguments
        let reply = UpdateLaunchReply()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            Task { @MainActor in reply.application = application; reply.error = error; reply.finished = true }
        }
        for _ in 0..<240 { if reply.finished { break }; try await Task.sleep(nanoseconds: 250_000_000) }
        guard reply.finished else { throw UpdateInstallFailure("系统启动请求超时，正在检查并还原…") }
        if let error = reply.error { throw error }
        guard let application = reply.application else { throw UpdateInstallFailure("新版未能启动") }
        return application
    }
    private func runningTarget() -> Bool { NSWorkspace.shared.runningApplications.contains { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == job.target.standardizedFileURL.resolvingSymlinksInPath() } }
    private func fail(_ error: Error, status resultStatus: String = "failed") {
        busy = false; status.stringValue = error.localizedDescription; done.isHidden = false; backupButton.isHidden = transaction == nil
        try? UpdateInstallResult(job: job, backup: transaction?.backup, status: resultStatus, message: error.localizedDescription).write(to: job.resultURL)
    }
    @objc private func close() { NSApp.terminate(nil) }
    @objc private func revealBackup() { if let backup = transaction?.backup { NSWorkspace.shared.activateFileViewerSelecting([backup]) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if !busy { NSApp.terminate(nil) }; return !busy }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
}

@main struct UpdateHelperMain {
    @MainActor static func main() {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--job" else { return }
            let job = try UpdateInstallJob.load(URL(fileURLWithPath: CommandLine.arguments[2])), app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = UpdateHelperDelegate(job: job); app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch { fputs((error.localizedDescription+"\n"), stderr) }
    }
}
