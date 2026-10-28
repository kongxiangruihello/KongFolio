import SwiftUI
import AppKit

struct ShortcutManagerView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var library: BookLibrary
    @State private var message = ""
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("集中管理此版本保存或拷贝过的阅读链接；旧快捷方式可手动导入。").font(.caption).foregroundStyle(.secondary)
            PanelRow { TextField("搜索快捷方式", text: $query); Button("导入已有快捷方式…") { importFiles() } }
            List(library.shortcuts.filter { query.isEmpty || ($0.shortcut.title + $0.shortcut.path).localizedCaseInsensitiveContains(query) }) { item in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("快捷方式名称", text: Binding(get: { library.shortcuts.first { $0.id == item.id }?.shortcut.title ?? "" }, set: { value in perform { try library.renameShortcut(item.id, title: value) } })).font(.headline)
                    Text(item.shortcut.mode.title + (item.shortcut.mode == .fixed ? " · 第 \(item.shortcut.position.selection + 1) 页" : "")).font(.caption)
                    Text(item.shortcut.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    PanelRow {
                        Button("打开") { perform { try store.openReadingShortcut(library.resolve(item.shortcut)); store.showReadingHistory = false } }
                        Button("拷贝链接") { perform { let link = try library.resolve(item.shortcut).link(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string); message = "已拷贝链接" } }
                        Button("重新指定书籍…") { relink(item) }
                        Button("另存快捷方式…") { export(item, existing: false) }
                        if let file = item.file {
                            Button("更新原快捷方式") { export(item, existing: true) }.help("保留原路径；Dock 中的入口继续可用，外部修改过的文件会停止更新")
                            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }.help("在访达中显示，可拖到 Dock 右侧")
                            Image(systemName: "book.closed").onDrag { NSItemProvider(object: file as NSURL) }.help("拖动到 Dock 分隔线后、废纸篓旁")
                        }
                        Button("移除记录") { perform { try library.removeShortcut(item.id) } }.help("只移除管理记录，原文件和导出的快捷方式保留")
                    }
                }.padding(.vertical, 5)
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
    }
    private func importFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [ReadingShortcut.fileType]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        perform { for url in panel.urls { try library.register(ReadingShortcut.read(url), file: url) }; message = "已导入快捷方式" }
    }
    private func relink(_ item: ManagedReadingShortcut) {
        let panel = NSOpenPanel(); panel.message = "选择这本书现在所在的文件，固定页码及阅读记录保留。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try library.relink(path: item.shortcut.path, to: url, defaults: store.readingDefaults); message = "书籍位置已更新。点“更新原快捷方式”可同步磁盘文件，Dock 中的位置保留。" }
    }
    private func export(_ item: ManagedReadingShortcut, existing: Bool) {
        let target: URL
        if existing, let file = item.file { target = file }
        else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [ReadingShortcut.fileType]
            panel.nameFieldStringValue = item.shortcut.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + ReadingShortcut.fileExtension
            guard panel.runModal() == .OK, let url = panel.url else { return }; target = url
        }
        perform { try library.exportShortcut(item.id, to: target); message = "快捷方式已保存，可从访达拖到 Dock 右侧。" }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
}
