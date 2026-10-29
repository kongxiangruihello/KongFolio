import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var controller: AppUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(Brand.accent); VStack(alignment: .leading) { Text("KongFolio 更新").font(.title2.bold()); Text("当前版本 "+controller.current.description).foregroundStyle(.secondary) }; Spacer() }
            Text(controller.message).textSelection(.enabled).accessibilityLabel("更新状态").accessibilityValue(controller.message)
            if controller.phase == .downloading {
                ProgressView(value: controller.progress.fraction).accessibilityLabel("更新下载进度")
                Text(controller.progress.label).monospacedDigit().accessibilityLabel("已下载大小和百分比")
            } else if controller.busy { ProgressView().controlSize(.small) }
            if let release = controller.release {
                Text("最新正式版本 "+release.version.description).font(.headline)
                ScrollView { Text(release.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 100, maxHeight: .infinity)
            } else { Spacer(minLength: 20) }
            Text("下载安装包时可以继续阅读。下载后先校验文件，再由你打开安装包；安装在访达中完成。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查更新") { controller.check() }.disabled(controller.busy)
                if controller.canDownload { Button("下载更新") { controller.download() }.keyboardShortcut(.defaultAction) }
                if controller.file != nil && !controller.busy { Button("打开安装包") { controller.openInstaller() }.keyboardShortcut(.defaultAction); Button("在访达中显示") { if let file = controller.file { NSWorkspace.shared.activateFileViewerSelecting([file]) } } }
                if controller.busy { Button("取消") { controller.cancel() } }
                Spacer()
                if let release = controller.release { Link("发布页面", destination: release.page) }
            }
        }.padding(24).frame(minWidth: 500, minHeight: 390)
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
        return AppUpdateController(current: AppUpdateVersion(version) ?? AppUpdateVersion("0.0.0")!)
    }()
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "检查 KongFolio 更新"; window.identifier = NSUserInterfaceItemIdentifier("kongfolio-update"); window.minSize = NSSize(width: 500, height: 390); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppUpdateView(controller: controller)); window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        if controller.phase == .idle { controller.check() }
    }
}
