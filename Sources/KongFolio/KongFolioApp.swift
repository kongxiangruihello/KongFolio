import SwiftUI
import AppKit

@main struct KongFolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = WorkspaceStore()
    @AppStorage(LayoutKeys.sidebar) private var showSidebar = true
    @AppStorage(LayoutKeys.inspector) private var showInspector = true
    @AppStorage(LayoutKeys.board) private var showBoard = false

    init() {
        AppLanguage.apply()
        AppInterface.registerDefaults()
        AppWarmup.start()
    }

    var body: some Scene {
        Window("KongFolio", id: "workspace") {
            RootView(store: store)
                .frame(minWidth: 380, minHeight: 300)
                .background(WindowAccessor { window in delegate.attach(window) })
                .onAppear { delegate.store = store; store.bootstrap() }
                .onOpenURL { url in
                    if TextImport.markdownExtensions.contains(url.pathExtension.lowercased()) { store.openNote(url) }
                    else { store.openInNewTab([url]) }
                }
        }
        // The window can be dragged to any size, from a narrow reading strip to a full screen.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { store.open() }.keyboardShortcut("o")
                Button("新建 Markdown 笔记") { store.newNote() }.keyboardShortcut("n")
                Button("编辑 Markdown 文件…") { store.editMarkdownFile() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { store.saveActive() }.keyboardShortcut("s").disabled(!store.canSave)
                Button("另存为…") { store.saveActive(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.canSave)
                Button("导出 PDF…") { store.exportActive() }.keyboardShortcut("e").disabled(!store.canSave)
                Button("关闭标签页") { store.closeActive() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!store.canCloseActive)
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
    weak var store: WorkspaceStore?
    private weak var window: NSWindow?
    private var closingApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if closingApproved { return .terminateNow }
        return store?.prepareToClose() == false ? .terminateCancel : .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store?.prepareToClose() != false else { return false }
        closingApproved = true
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
