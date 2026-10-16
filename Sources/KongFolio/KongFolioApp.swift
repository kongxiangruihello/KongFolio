import SwiftUI
import AppKit

@main struct KongFolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("KongFolio", id: "workspace") {
            ContentView(workspace: workspace)
                .frame(minWidth: 1060, minHeight: 720)
                .background(WindowAccessor { window in delegate.attach(window) })
                .onAppear { delegate.workspace = workspace; workspace.bootstrap() }
                .onOpenURL { workspace.load([$0]) }
        }
        .commands {
            CommandGroup(replacing: .newItem) { Button("打开…") { workspace.open() }.keyboardShortcut("o") }
            CommandGroup(replacing: .saveItem) {
                Button("保存项目…") { workspace.saveProject() }.keyboardShortcut("s").disabled(workspace.count == 0 || workspace.busy)
                Button("项目另存为…") { workspace.saveProject(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(workspace.count == 0 || workspace.busy)
                Button("导出 PDF…") { workspace.exportPDF() }.keyboardShortcut("e").disabled(workspace.count == 0 || workspace.busy)
                Button("关闭文档或图片") { workspace.closeDocument() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(workspace.count == 0 || workspace.busy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { workspace.undo() }.keyboardShortcut("z").disabled(!workspace.canUndo || workspace.busy)
                Button("重做") { workspace.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.canRedo || workspace.busy)
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
    weak var workspace: Workspace?
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
        return workspace?.prepareToClose() == false ? .terminateCancel : .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace?.prepareToClose() != false else { return false }
        closingApproved = true
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
