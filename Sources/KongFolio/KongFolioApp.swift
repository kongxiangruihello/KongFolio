import SwiftUI
import AppKit

@main struct KongFolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = WorkspaceStore()
    @AppStorage(LayoutKeys.sidebar) private var showSidebar = true
    @AppStorage(LayoutKeys.inspector) private var showInspector = true

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
                Button("专注阅读（隐藏/恢复两侧栏）") {
                    let show = !showSidebar && !showInspector
                    showSidebar = show; showInspector = show
                }.keyboardShortcut("3", modifiers: [.command, .option])
            }
            CommandMenu("标签页") {
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
