import SwiftUI

/// Tab bar above the active tab's content.
struct RootView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            TabBar(store: store)
            Divider()
            if let tab = store.activeTab {
                switch tab {
                case .document(let workspace): ContentView(workspace: workspace,readingMode:store.readingMode).id(workspace.id)
                case .note(let note): MarkdownEditorView(note: note, store: store).id(note.id)
                }
            } else {
                Color.clear
            }
        }
        .task { await store.importLegacyReadingRecords() }
        .onChange(of:store.readingDeskWindowRequest) { _,request in if request != nil { ReadingDeskWindowManager.shared.show(store) } }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in store.checkOpenSourceChanges() }
        .onChange(of: store.showResearch) { _,show in
            if show { ResearchWindowManager.shared.show(store); store.showResearch = false }
        }
        .sheet(isPresented: $store.showStartupReview) { StartupReviewView(store:store) }
        .sheet(isPresented: $store.showReadingHistory) { ReadingHistorySheet(store: store) }
        .sheet(isPresented: $store.showHistorySettings) { HistorySettingsView(storage: store.storage) }
        .sheet(item: $store.notebookBook) { BookNotebookView(store: store, library: store.library, book: $0) }
        .sheet(item: $store.exportReview) { request in ExportReviewSheet(store: store, request: request) }
        .sheet(isPresented: $store.showBackgroundJobs) { DocumentTasksView(queue: store.documentTasks, store: store) }
        .sheet(isPresented: $store.showRecoveryCenter) { RecoveryCenterView(store: store) }
        .sheet(isPresented: $store.showDocumentComparison) { DocumentComparisonPanel() }
        .sheet(item: $store.pendingPageTransfer) { request in PageTransferSheet(store: store, request: request) }
        .sheet(isPresented: $store.showTaskCenter) { TaskCenterPanel(queue: store.batchQueue, replacements: []) }
        .sheet(isPresented: $store.showCommandPalette) { CommandPaletteView(store: store) }
        .sheet(isPresented: $store.showSwitcher) { TabSwitcherView(store: store) }
        .sheet(isPresented: $store.showFolderSearch,onDismiss:{
            if store.showOCRTasksAfterSearch { store.showOCRTasksAfterSearch=false;store.showTaskCenter=true }
        }) { FolderSearchView(store:store,model:store.folderSearch) }
    }
}

struct TabBar: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.tabs) { tab in
                            TabItem(store: store, tab: tab, selected: tab.id == store.selectedID, compact: store.tabs.count > 8)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                // With dozens of tabs the selected one may be off screen (keyboard switching, the list menu, a new tab).
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button { store.showReadingHistory = true } label: { Image(systemName: "books.vertical") }
                .buttonStyle(.borderless).frame(width: 28).help("个人书架、阅读记录与书籍快捷方式")
            Button { store.openReadingDesk(.search,window:true) } label: { Image(systemName: "note.text") }.buttonStyle(.borderless).help("查找自己的摘录、笔记与札记")
            DocumentTaskButton(queue: store.documentTasks, store: store)
            Menu {
                ForEach(store.tabs) { tab in
                    Button { store.select(tab.id) } label: {
                        if tab.id == store.selectedID { Label(tabName(tab), systemImage: "checkmark") } else { Text(tabName(tab)) }
                    }
                }
            } label: { Image(systemName: "list.bullet") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("所有已打开的文件（共 \(store.tabs.count) 个）")
            Menu {
                Button("打开文档…") { store.open() }
                Button("跨文件全文搜索…") { store.showFolderSearch=true }
                Divider()
                Button("新建 Markdown 笔记") { store.newNote() }
                Button("新建 HTML 文件") { store.newNote(format: .html) }
                Button("新建文本文件") { store.newNote(format: .plain) }
                Button("编辑文本文件…") { store.editMarkdownFile() }
            } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("新建标签页：打开文件，或新建/编辑 Markdown")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(.bar)
    }

    private func tabName(_ tab: OpenTab) -> String {
        switch tab {
        case .document(let workspace): return workspace.count == 0 && workspace.sourceURL == nil && workspace.projectURL == nil ? "新标签页" : workspace.displayName
        case .note(let note): return note.title
        }
    }
}

private struct TabItem: View {
    @ObservedObject var store: WorkspaceStore
    let tab: OpenTab
    let selected: Bool
    let compact: Bool

    var body: some View {
        switch tab {
        case .document(let workspace): DocumentTab(store: store, workspace: workspace, selected: selected, compact: compact)
        case .note(let note): NoteTab(store: store, note: note, selected: selected, compact: compact)
        }
    }
}

private struct DocumentTab: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    let selected: Bool
    let compact: Bool

    var body: some View {
        let known = workspace.sourceURL != nil || workspace.projectURL != nil
        let loading = workspace.count == 0 && workspace.busy
        TabChip(icon: loading ? "arrow.down.circle" : (workspace.count == 0 ? (known ? "doc" : "tray") : "doc.richtext"),
                title: workspace.count == 0 && !known ? "新标签页" : workspace.displayName,
                tooltip: workspace.displayPath ?? "",
                dirty: workspace.dirty && workspace.count > 0, selected: selected, compact: compact,
                dimmed: workspace.count == 0 && known && !loading,
                hover: { inside in store.setPathHint(inside ? Workspace.pathHintText(path: workspace.displayPath, title: workspace.title) : nil) },
                select: { store.select(workspace.id) }, close: { store.close(workspace.id) })
            .onDrop(of: [.utf8PlainText], delegate: PageDropDelegate(workspace: workspace))
            .contextMenu {
                if workspace.displayPath != nil {
                    Button("拷贝完整路径") { workspace.copyPath() }
                    Button("在访达中显示") { workspace.revealInFinder() }
                    Divider()
                }
                if !selected, store.activeWorkspace != nil {
                    Button("在右侧并排阅读（与当前文档对照）") { store.openSplit(with: workspace.id) }
                }
            }
    }
}

private struct NoteTab: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var note: MarkdownNote
    let selected: Bool
    let compact: Bool

    var body: some View {
        TabChip(icon: "square.and.pencil", title: note.title, tooltip: note.fileURL?.path ?? "尚未保存到文件", dirty: note.dirty, selected: selected, compact: compact, dimmed: false,
                hover: { inside in store.setPathHint(inside ? (note.fileURL.map { "文件：" + $0.path } ?? "尚未保存到文件") : nil) },
                select: { store.select(note.id) }, close: { store.close(note.id) })
    }
}

private struct TabChip: View {
    let icon: String
    let title: String
    let tooltip: String
    let dirty: Bool
    let selected: Bool
    let compact: Bool
    let dimmed: Bool
    var hover: (Bool) -> Void = { _ in }
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title + (dirty ? " •" : "")).lineLimit(1).truncationMode(.middle).frame(maxWidth: compact ? 130 : 200, alignment: .leading)
                .foregroundStyle(dimmed ? .secondary : .primary)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain)
                .help("关闭此标签页")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(tooltip)
        .onHover { hover($0) }
    }
}


@MainActor final class ResearchWindowManager {
    static let shared = ResearchWindowManager()
    private var windows: [ObjectIdentifier:NSWindowController] = [:]
    func show(_ store: WorkspaceStore) {
        let key = ObjectIdentifier(store)
        if let controller = windows[key] { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.identifier = NSUserInterfaceItemIdentifier("research-workbench"); window.title = "阅读与史料研究"; window.minSize = NSSize(width:660,height:420); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ResearchPanel(store:store,research:store.research,onClose:{ [weak window] in window?.close() }))
        let controller = NSWindowController(window:window); windows[key] = controller
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
}
