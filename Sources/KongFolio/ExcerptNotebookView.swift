import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ExcerptNotebookView: View {
    @ObservedObject var board: Board
    let store: WorkspaceStore?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var title = "摘录笔记"
    @State private var grouping = ExcerptNotebook.Grouping.file
    @State private var includeSources = true
    @State private var working = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("摘录生成 Markdown 笔记").font(.title2.bold())
            TextField("笔记标题", text: $title)
            PanelRow {
                Picker("汇总方式", selection: $grouping) { ForEach(ExcerptNotebook.Grouping.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 230)
                Button("全选") { selected = Set(board.cards.map(\.id)) }
                Button("清空选择") { selected = [] }
                Spacer(); Text("已选 \(selected.count) 张")
            }
            List(board.cards) { card in
                Toggle(isOn: Binding(get: { selected.contains(card.id) }, set: { if $0 { selected.insert(card.id) } else { selected.remove(card.id) } })) {
                    VStack(alignment: .leading) {
                        Text(card.kind == .image ? "图片摘录" : card.text).lineLimit(2)
                        if let source = card.source { Text(source.fileName + " · " + source.pageDescription).font(.caption).foregroundStyle(.secondary) }
                        if !card.comment.isEmpty { Text("评论：" + card.comment).font(.caption).lineLimit(1) }
                    }
                }
            }
            Text("引文、评论和出处分别保留；“返回原文”链接由 KongFolio 打开。按章节使用来源文件目录，没有目录的内容列入“未分章”。图片直接嵌入笔记；导出资料包可携带引用的原件，解压后从笔记返回原文。").font(.caption).foregroundStyle(.secondary)
            Toggle("资料包包含引用的原件", isOn: $includeSources)
            if !message.isEmpty { Text(message).font(.caption) }
            PanelRow {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("导出资料包…") { package() }.disabled(selected.isEmpty || working)
                Button("生成并编辑") { create() }.disabled(selected.isEmpty || store == nil || working).keyboardShortcut(.defaultAction)
            }
        }.padding(20).adaptiveSheet(width: 720, height: 600, minimumWidth: 360).disabled(working)
        .onAppear { selected = Set(board.cards.map(\.id)); title = board.displayTitle + " · 摘录笔记" }
    }
    private func package() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "摘录资料包.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cards = board.cards.filter { selected.contains($0.id) }, title = title, grouping = grouping, include = includeSources
        working = true; message = "正在打包…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try NotebookPackage.write(cards: cards, title: title, grouping: grouping, includeSources: include, to: url) }.value
                message = "资料包已导出，解压后请打开其中的摘录笔记.md"
            } catch { message = "打包失败：" + error.localizedDescription }
            working = false
        }
    }
    private func create() {
        guard let store else { return }
        let cards = board.cards.filter { selected.contains($0.id) }, heading = title, grouping = grouping
        working = true
        Task {
            let outlines = await Task.detached(priority: .userInitiated) { () -> [String: [OutlineEntry]] in
                guard grouping == .chapter else { return [:] }
                var result: [String: [OutlineEntry]] = [:]
                for path in Set(cards.compactMap { $0.source?.path }) where URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
                    if let document = PDFDocument(url: URL(fileURLWithPath: path)) { result[path] = ReadingServices.outline(document) }
                }
                return result
            }.value
            var current = outlines
            for workspace in store.tabs.compactMap(\.workspace) where workspace.count > 0 {
                if let path = (workspace.projectURL ?? workspace.sourceURL)?.path { current[path] = workspace.outlineEntries }
            }
            let text = ExcerptNotebook.render(cards, title: heading, grouping: grouping, outlines: current)
            dismiss()
            let note = store.newNote(); note.text = text; note.dirty = true; note.status = "已从 \(cards.count) 张卡片生成笔记，可编辑、保存或导出"
        }
    }
}
