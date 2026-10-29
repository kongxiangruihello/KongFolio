import SwiftUI

struct ResearchRestorePreview: View {
    @ObservedObject var controller: ResearchController
    @ObservedObject var store: WorkspaceStore
    @State private var rows: [ResearchRestoreRow] = []
    @State private var query = ""
    @State private var page = 0
    @State private var loading = false
    private var filtered: [ResearchRestoreRow] { rows.filter { query.isEmpty || $0.book.title.localizedCaseInsensitiveContains(query) } }
    private var lastPage: Int { max(0,(filtered.count-1)/25) }
    private var visible: [ResearchRestoreRow] { Array(filtered.dropFirst(min(page,lastPage)*25).prefix(25)) }
    var body: some View {
        if let backup = controller.backupPreview {
            VStack(alignment:.leading,spacing:10) {
                Text("恢复前核对").font(.headline)
                Text("书籍 \(backup.catalog.books.count) 本 · 伴随资料 \(backup.companions.count) 份 · 阅读记录 \(backup.progress.count) 本 · 草稿 \(backup.companions.filter { $0.path.contains("Drafts/") }.count) 份").font(.caption)
                selectionControls(backup)
                if loading { ProgressView("正在核对书架记录…") }
                ScrollView {
                    LazyVStack(alignment:.leading) { ForEach(visible) { row in bookRow(row) } }
                }.frame(height:260)
                pagination
                Toggle("同时恢复公共笔记、图片资源和工作区",isOn:$controller.backupIncludeShared)
                Text("所选书籍的书签、校对、阅读尺和草稿随书恢复；共享笔记可单独选择。所有文件先恢复到新目录，已有资料继续保留。").font(.caption)
                HStack {
                    Button("选择目录并恢复所选资料…") { controller.restoreSelectedBackup(store) }.disabled(controller.busy || loading || (controller.backupSelection.isEmpty && !controller.backupIncludeShared))
                    Button("关闭预览") { controller.backupPreview = nil }.disabled(controller.busy)
                }
            }.padding(10).background(.quaternary.opacity(0.3))
            .task(id:backup.created) { await load(backup) }
            .onChange(of:query) { _,_ in page = 0 }
        }
    }
    private func selectionControls(_ backup: ResearchBackup) -> some View {
        HStack {
            TextField("筛选备份中的书名",text:$query)
            Button("全选") { controller.backupSelection = Set(backup.catalog.books.map(\.path)) }
            Button("全不选") { controller.backupSelection = [] }
            Text("已选 \(controller.backupSelection.count) 本").font(.caption)
        }
    }
    private var pagination: some View {
        HStack {
            Text("筛选结果 \(filtered.count) 本").font(.caption); Spacer()
            Button("上一页") { page = max(0,page-1) }.disabled(page == 0)
            Text("第 \(min(page,lastPage)+1) / \(lastPage+1) 页").font(.caption)
            Button("下一页") { page += 1 }.disabled(page >= lastPage)
        }
    }
    private func bookRow(_ row: ResearchRestoreRow) -> some View {
        HStack {
            Toggle(row.book.title,isOn:Binding(get:{controller.backupSelection.contains(row.book.path)},set:{ if $0 { controller.backupSelection.insert(row.book.path) } else { controller.backupSelection.remove(row.book.path) } })).lineLimit(1).help(row.book.title)
            Spacer()
            Text(row.hasOriginal ? "含原件副本" : "未打包原件，恢复时检查位置").font(.caption)
            if row.exists { Text("书架已有记录；含原件时另建独立副本").font(.caption).foregroundStyle(.orange) }
        }
    }
    private func load(_ backup: ResearchBackup) async {
        loading = true; rows = []; page = 0
        let books = backup.catalog.books, originals = Set(backup.originals.keys), existing = store.library.books
        let prepared = await Task.detached(priority:.utility) { ResearchRestoreRow.prepare(books:books,originals:originals,existing:existing) }.value
        guard !Task.isCancelled else { return }
        rows = prepared; loading = false
    }
}
