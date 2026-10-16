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
                case .document(let workspace): ContentView(workspace: workspace).id(workspace.id)
                case .note(let note): MarkdownEditorView(note: note).id(note.id)
                }
            } else {
                Color.clear
            }
        }
    }
}

struct TabBar: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        TabItem(store: store, tab: tab, selected: tab.id == store.selectedID)
                    }
                }
                .padding(.horizontal, 8)
            }
            Menu {
                Button("打开文档或图片…") { store.open() }
                Divider()
                Button("新建 Markdown 笔记") { store.newNote() }
                Button("编辑 Markdown 文件…") { store.editMarkdownFile() }
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
}

private struct TabItem: View {
    @ObservedObject var store: WorkspaceStore
    let tab: OpenTab
    let selected: Bool

    var body: some View {
        switch tab {
        case .document(let workspace): DocumentTab(store: store, workspace: workspace, selected: selected)
        case .note(let note): NoteTab(store: store, note: note, selected: selected)
        }
    }
}

private struct DocumentTab: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    let selected: Bool

    var body: some View {
        TabChip(icon: workspace.count == 0 ? "tray" : (workspace.mode == .image ? "photo" : "doc.richtext"),
                title: workspace.count == 0 ? "新标签页" : workspace.title,
                dirty: workspace.dirty && workspace.count > 0, selected: selected,
                select: { store.select(workspace.id) }, close: { store.close(workspace.id) })
    }
}

private struct NoteTab: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var note: MarkdownNote
    let selected: Bool

    var body: some View {
        TabChip(icon: "square.and.pencil", title: note.title, dirty: note.dirty, selected: selected,
                select: { store.select(note.id) }, close: { store.close(note.id) })
    }
}

private struct TabChip: View {
    let icon: String
    let title: String
    let dirty: Bool
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title + (dirty ? " •" : "")).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
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
    }
}
