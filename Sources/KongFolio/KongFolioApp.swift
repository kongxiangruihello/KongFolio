import SwiftUI
import AppKit
#if canImport(KongFolioUpdateKit)
import KongFolioUpdateKit
#endif

@main struct KongFolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = WorkspaceStore()
    @AppStorage(LayoutKeys.sidebar) private var showSidebar = true
    @AppStorage(LayoutKeys.inspector) private var showInspector = true
    @AppStorage(LayoutKeys.board) private var showBoard = false

    init() {
        AppLanguage.apply()
        AppInterface.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("KongFolio", id: "workspace") {
            RootView(store: store)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .frame(minWidth: 380, minHeight: 300)
                .background(WindowAccessor { window in delegate.attach(window) })
                .onAppear { delegate.store = store; store.bootstrap(); AppUpdateInstaller.acknowledgeLaunch() }
                .onOpenURL { url in delegate.externalDocuments.receive([url]) }
        }
        .handlesExternalEvents(matching: ["*"])
        // The window can be dragged to any size, from a narrow reading strip to a full screen.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { AppUpdateWindow.shared.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("打开…") { store.open() }.keyboardShortcut("o")
                Button("新建 PDF") { store.newPDF() }
                Button("新建 Markdown 笔记") { store.newNote() }.keyboardShortcut("n")
                Button("新建 HTML 文件") { store.newNote(format: .html) }
                Button("新建文本文件") { store.newNote(format: .plain) }
                Button("编辑 Markdown / HTML / 文本文件…") { store.editMarkdownFile() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { store.saveActive() }.keyboardShortcut("s").disabled(!store.canSave)
                Button("另存为…") { store.saveActive(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.canSave)
                Button("导出 PDF…") { store.exportActive() }.keyboardShortcut("e").disabled(!store.canSave)
                Button("导出 Word…") { store.exportWordActive() }.disabled(!store.canSave)
                Button("关闭标签页") { store.closeActive() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!store.canCloseActive)
            }
            CommandMenu("阅读") {
                Button("阅读与史料研究…") { store.showResearch = true }
                Button("显示／隐藏阅读尺") { if let w = store.commandWorkspace { w.loadReadingRulerIfNeeded(); w.readingRuler.enabled.toggle() } }.disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("阅读尺前移") { store.commandWorkspace?.readingRuler.move(-0.04) }.keyboardShortcut(.upArrow,modifiers:[.command,.option])
                Button("阅读尺后移") { store.commandWorkspace?.readingRuler.move(0.04) }.keyboardShortcut(.downArrow,modifiers:[.command,.option])
                Button("复制当前选文的史料引文") { do { _ = try store.commandWorkspace?.copyResearchCitation() } catch { store.commandWorkspace?.error = error.localizedDescription } }
                Button("个人书架与阅读记录…") { store.showReadingHistory = true }
                Button("当前书籍的阅读笔记…") { store.openCurrentBookNotebook() }.disabled(store.commandWorkspace?.canCreateReadingShortcut != true)
                Button("当前书籍的阅读进度…") { store.commandWorkspace?.refreshProgress(); store.commandWorkspace?.showProgress = true }.disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("保存阅读快捷方式…") { store.commandWorkspace?.showReadingShortcut = true }.disabled(store.commandWorkspace?.canCreateReadingShortcut != true)
                Button("拷贝继续阅读链接") { store.commandWorkspace?.report { try store.commandWorkspace?.copyReadingLink(mode: .resume) } }.disabled(store.commandWorkspace?.canCreateReadingShortcut != true)
            }
            CommandMenu("任务与历史") {
                Button("导出检查…") { store.performCommand(.exportCheck) }
                Button("恢复中心…") { store.showRecoveryCenter = true }
                Button("历史版本与备份空间…") { store.showHistorySettings = true }
                Button("当前文本文件的历史…") { store.activeNote?.showVersionHistory = true }.disabled(store.activeNote?.fileURL == nil)
                Button("后台任务…") { store.showBackgroundJobs = true }
                Button("制作 / 套用扫描表单模板…") { store.commandWorkspace?.showFormTemplate = true }.disabled((store.commandWorkspace?.count ?? 0) == 0 || store.commandWorkspace?.busy == true)
                Button("搜索命令…") { store.showCommandPalette = true }.keyboardShortcut("k")
                Button("提取 PDF 表格…") { store.commandWorkspace?.showTableExtraction = true }.disabled((store.commandWorkspace?.count ?? 0) == 0 || store.commandWorkspace?.busy == true)
                Button("填写 PDF 表单…") { store.commandWorkspace?.showPDFForms = true }.disabled((store.commandWorkspace?.count ?? 0) == 0 || store.commandWorkspace?.busy == true)
                Button("OCR 批量纠错…") { store.commandWorkspace?.showOCRBatchCorrection = true }.disabled((store.commandWorkspace?.count ?? 0) == 0 || store.commandWorkspace?.busy == true)
                Button("文档精细对比…") { store.showDocumentComparison = true }
                Button("跨文件全文搜索…") { store.showFolderSearch=true }.keyboardShortcut("f",modifiers:[.command,.shift])
                Button("空白页与重复页检查…") { store.activeWorkspace?.showPageInspection = true }.disabled((store.activeWorkspace?.count ?? 0) == 0)
                Button("任务中心与扫描配方…") { store.showTaskCenter = true }.keyboardShortcut("j", modifiers: [.command, .option])
                Button("当前文档的保存历史…") { store.activeWorkspace?.showVersionHistory = true }
                    .disabled(store.activeWorkspace?.historySource == nil || store.activeWorkspace?.busy == true)
            }
            CommandGroup(replacing: .printItem) {
                Button("打印…") { store.printActive() }.keyboardShortcut("p").disabled(!store.canSave)
            }
            CommandGroup(replacing: .sidebar) {
                Button(showSidebar ? "隐藏左侧栏" : "显示左侧栏") { showSidebar.toggle() }.keyboardShortcut("1", modifiers: [.command, .option])
                Button(showInspector ? "隐藏右侧栏" : "显示右侧栏") { showInspector.toggle() }.keyboardShortcut("2", modifiers: [.command, .option])
                Button((store.commandWorkspace?.nightReading ?? false) ? "关闭夜间阅读" : "夜间阅读（页面反色）") {
                    if let w = store.commandWorkspace { w.nightReading.toggle() }
                }.keyboardShortcut("d", modifiers: [.command, .option]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("专注阅读（隐藏/恢复两侧栏）") {
                    let show = !showSidebar && !showInspector
                    showSidebar = show; showInspector = show
                }.keyboardShortcut("3", modifiers: [.command, .option])
            }
            CommandGroup(after: .pasteboard) {
                Button("查找下一处") { store.commandWorkspace?.stepSearch(1) }.keyboardShortcut("g").disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("查找上一处") { store.commandWorkspace?.stepSearch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("复制（竖排按列从右到左）") { store.commandWorkspace?.copyInReadingOrder() }
                    .keyboardShortcut("c", modifiers: [.command, .option]).disabled((store.commandWorkspace?.count ?? 0) == 0)
            }
        }
        // Older SDKs accept at most ten top-level commands in each CommandsBuilder.
        .commands {
            CommandGroup(after: .help) {
                Button("复制诊断信息（反馈问题时用）") { store.commandWorkspace?.copyDiagnostics() }
                Button("开启 / 关闭悬停提示诊断") { TooltipDiagnostics.shared.toggle() }
                Button("在访达中显示悬停诊断记录") { TooltipDiagnostics.shared.revealLog() }
                Button("在访达中显示性能日志（识别、批量处理耗时）") {
                    if FileManager.default.fileExists(atPath: PerfLog.url.path) { NSWorkspace.shared.activateFileViewerSelecting([PerfLog.url]) }
                }
            }
            CommandMenu("标注") {
                Button("复制标注") { store.commandWorkspace?.copySelectedAnnotations() }.keyboardShortcut("c", modifiers: [.command, .option, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("粘贴标注") { store.commandWorkspace?.pasteAnnotations() }.keyboardShortcut("v", modifiers: [.command, .option, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("再制所选标注") { store.commandWorkspace?.duplicateSelectedAnnotations() }.keyboardShortcut("d").disabled((store.commandWorkspace?.count ?? 0) == 0)
                Divider()
                Button((store.commandWorkspace?.showAnnotationBar ?? true) ? "隐藏标注工具栏" : "显示标注工具栏") {
                    if let w = store.commandWorkspace { w.showAnnotationBar.toggle() }
                }.keyboardShortcut("a", modifiers: [.command, .option]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Divider()
                Button("高亮选中文字") { if let w = store.commandWorkspace { w.mark(style: .highlight, color: w.markupColor) } }
                    .keyboardShortcut("h", modifiers: [.command, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("下划线") { if let w = store.commandWorkspace { w.mark(style: .underline, color: w.markupColor) } }
                    .keyboardShortcut("u", modifiers: [.command, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("删除线") { if let w = store.commandWorkspace { w.mark(style: .strikeOut, color: w.markupColor) } }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("高亮并添加批注") { if let w = store.commandWorkspace { w.mark(style: .highlight, color: w.markupColor, annotate: true) } }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled((store.commandWorkspace?.count ?? 0) == 0)
            }
            CommandMenu("编辑页面") {
                Button("扫描整理：切分 / 纠偏 / 检查…") { store.commandWorkspace?.showScanWorkshop = true }
                    .disabled((store.commandWorkspace?.count ?? 0) == 0 || store.commandWorkspace?.busy == true)
                Menu("选择页面") {
                    ForEach(PageSelectionKind.allCases) { kind in
                        Button(kind.rawValue) { store.commandWorkspace?.selectPages(kind) }
                    }
                }.disabled(store.commandWorkspace?.busy != false || (store.commandWorkspace?.count ?? 0) == 0)
                Button("反转选中页顺序") { store.commandWorkspace?.reverseSelectedPages() }
                    .disabled(store.commandWorkspace?.busy != false || (store.commandWorkspace?.count ?? 0) < 2)
                Button("还原双面扫描页序…") { store.commandWorkspace?.restoreDuplexOrder() }
                    .disabled(store.commandWorkspace?.busy != false || (store.commandWorkspace?.count ?? 0) < 2)
                Divider()
                Button("在当前页后插入空白页") { store.commandWorkspace?.insertBlankPage() }.disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("在当前页前插入空白页") { store.commandWorkspace?.insertBlankPage(before: true) }.disabled((store.commandWorkspace?.count ?? 0) == 0)
                Divider()
                Button("给选中文字加链接…") {
                    if let w = store.commandWorkspace, let text = TextPrompt.ask("链接去向", detail: "输入页码（1–\(w.count)）跳到那一页，或输入网址。", button: "加链接") { w.addLinkToSelection(text) }
                }.disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button("去掉选中文字上的链接") { store.commandWorkspace?.removeLinksInSelection() }.disabled((store.commandWorkspace?.count ?? 0) == 0)
            }
            CommandMenu("工作区") {
                Button("摘录选中文字到工作区") { store.commandWorkspace?.excerptSelection() }
                    .keyboardShortcut("e", modifiers: [.command, .option]).disabled((store.commandWorkspace?.count ?? 0) == 0)
                Button(showBoard ? "隐藏工作区" : "显示工作区") { showBoard.toggle() }.keyboardShortcut("4", modifiers: [.command, .option])
            }
            CommandMenu("标签页") {
                Button("快速切换标签页…") { store.showSwitcher = true }.keyboardShortcut("p")
                Divider()
                Button("下一个标签页") { store.selectNext() }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("上一个标签页") { store.selectPrevious() }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { store.undoActive() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("重做") { store.redoActive() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
        }
    }
}

/// Hands the hosting NSWindow to a callback, so the close guard attaches to this window
/// rather than to whichever window happens to be first in `NSApp.windows`.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var current: AppDelegate?
    let externalDocuments = ExternalDocumentRouter()
    weak var store: WorkspaceStore? { didSet { if let store { externalDocuments.attach(store) } } }
    private weak var window: NSWindow?
    private weak var approvedWindow: NSWindow?
    private var closeTaskRunning = false
    private var terminationApproved = false
    private var pendingUpdate: (UpdateInstallJob, (Error?) -> Void)?

    func installAndRestart(_ job: UpdateInstallJob, completion: @escaping (Error?) -> Void) throws {
        guard !closeTaskRunning, pendingUpdate == nil else { throw UpdateInstallFailure("正在保存或关闭文档，请稍后再安装") }
        pendingUpdate = (job, completion)
        AppUpdateInstaller.deferTermination { [weak self] in
            guard self?.pendingUpdate?.0.id == job.id else { return }
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        AppUpdateInstaller.acknowledgeLaunch()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if UserDefaults.standard.bool(forKey: TooltipDiagnostics.key) { TooltipDiagnostics.shared.start() }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window || window.delegate !== self else { return }
        self.window = window
        window.delegate = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard !closeTaskRunning else { return .terminateCancel }
        closeTaskRunning = true
        Task { [weak self] in
            guard let self else { return }
            let saved = await self.store?.finishPendingSaves() ?? true
            var approved = saved && self.store?.prepareToClose() != false
            if let (job, completion) = self.pendingUpdate {
                if approved {
                    do { try await AppUpdateInstaller.launchHelper(job) } catch { approved = false; completion(error) }
                } else { completion(UpdateInstallFailure("安装已取消，记录与原程序已保留，可稍后再试")) }
                self.pendingUpdate = nil
            }
            if approved, let store = self.store { StartupProtection(storage:store.storage).clean() }
            self.closeTaskRunning = false
            if approved {
                self.terminationApproved = true
                AppUpdateInstaller.deferTermination { sender.terminate(nil) }
            }
        }
        // Return to the ordinary event loop while asynchronous saves run. AppKit's
        // terminateLater loop can stop main-queue tasks requested by an update.
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedWindow === sender { approvedWindow = nil; return true }
        guard !closeTaskRunning else { return false }
        closeTaskRunning = true
        Task { [weak self, weak sender] in
            guard let self else { return }
            let saved = await self.store?.finishPendingSaves() ?? true
            self.closeTaskRunning = false
            guard saved, self.store?.prepareToClose() != false else { return }
            if let store = self.store { StartupProtection(storage:store.storage).clean() }
            self.approvedWindow = sender; sender?.performClose(nil)
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
