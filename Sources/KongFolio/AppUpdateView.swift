import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var controller: AppUpdateController
    var returnToReading: () -> Void = {}
    var install: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(Brand.accent); VStack(alignment: .leading) { Text("KongFolio 更新").font(.title2.bold()); Text("当前版本 "+controller.current.description).foregroundStyle(.secondary) }; Spacer(); Button("返回阅读", action: returnToReading).keyboardShortcut(.cancelAction) }
            Text(controller.message).textSelection(.enabled).accessibilityLabel("更新状态").accessibilityValue(controller.message)
            if controller.phase == .downloading {
                ProgressView(value: controller.progress.fraction).accessibilityLabel("更新下载进度")
                Text(controller.progress.label).monospacedDigit().accessibilityLabel("已下载大小和百分比").accessibilityValue(controller.progress.label)
            } else if controller.busy { ProgressView().controlSize(.small) }
            if let release = controller.release {
                Text("最新正式版本 "+release.version.description).font(.headline)
                ScrollView { Text(release.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 100, maxHeight: .infinity)
            } else { Spacer(minLength: 20) }
            Text("下载时可以继续阅读。在线安装会先保存记录，再安装并重新打开；上一版本保留。也可选择手动安装。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查更新") { controller.check() }.disabled(controller.busy)
                if controller.canDownload { Button("下载更新") { controller.download() }.keyboardShortcut(.defaultAction) }
                if controller.canInstall { Button("安装并重新打开", action: install).keyboardShortcut(.defaultAction) }
                if controller.file != nil && !controller.busy { Menu("手动安装") { Button("打开安装包") { controller.openInstaller() }; Button("在访达中显示") { if let file = controller.file { NSWorkspace.shared.activateFileViewerSelecting([file]) } } } }
                if controller.busy && controller.phase != .installing { Button("取消") { controller.cancel() } }
                Spacer()
                if let release = controller.release { Link("发布页面", destination: release.page) }
            }
            if let result = controller.installationResult {
                Text(result.message).font(.caption).foregroundStyle(.secondary)
                if let backup = result.backup, FileManager.default.fileExists(atPath: backup.path) { Button("在访达中显示上一版本") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }.font(.caption) }
            }
        }.padding(24).frame(minWidth: 500, minHeight: 480)
    }
}

@MainActor final class AppUpdateWindow {
    static let shared = AppUpdateWindow()
    private var window: NSWindow?
    private lazy var controller: AppUpdateController = {
        var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        // Only an explicitly renamed isolated QA bundle can simulate an older installed version.
        if Bundle.main.bundleIdentifier?.hasPrefix("com.kongfolio.qa") == true,
           ProcessInfo.processInfo.environment["KONGFOLIO_STORAGE"] != nil,
           let testVersion = ProcessInfo.processInfo.environment["KONGFOLIO_TEST_UPDATE_CURRENT"] { version = testVersion }
        let transport: any AppUpdateTransport = AppUpdateQAFixture.configured().map { $0 as any AppUpdateTransport } ?? AppUpdateNetwork()
        return AppUpdateController(current: AppUpdateVersion(version) ?? AppUpdateVersion("0.0.0")!, transport: transport)
    }()
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "检查 KongFolio 更新"; window.identifier = NSUserInterfaceItemIdentifier("kongfolio-update"); window.contentMinSize = NSSize(width: 500, height: 480); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppUpdateView(controller: controller, returnToReading: { [weak window] in window?.close() }, install: { [weak self] in self?.install() })); window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        if let delegate = AppDelegate.current, let storage = delegate.store?.storage { controller.loadInstallationResult(storage.appendingPathComponent("Updates/last-install.json")) }
        controller.check()
    }
    private func install() {
        guard let delegate = AppDelegate.current, let store = delegate.store, let identifier = Bundle.main.bundleIdentifier else { return }
        controller.install(target: Bundle.main.bundleURL, expectedIdentifier: identifier, resultURL: store.storage.appendingPathComponent("Updates/last-install.json"), parentLaunchDate: NSRunningApplication.current.launchDate) { job, completion in try delegate.installAndRestart(job, completion: completion) }
    }
}
