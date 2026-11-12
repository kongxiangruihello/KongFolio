import SwiftUI

struct ReadingHistoryOnlyView: View {
    @ObservedObject var store:WorkspaceStore
    @State private var history:[ReadingProgress.HistoryItem] = []
    @State private var selected = Set<String>()
    @State private var removed = Set<String>()
    @State private var confirmRemoval = false
    @State private var query = ""
    @State private var page = 0
    @State private var message = ""
    @State private var revision = UUID()
    private var matches:[ReadingProgress.HistoryItem] { history.filter{query.isEmpty || ($0.title+$0.path).localizedCaseInsensitiveContains(query)} }

    var body:some View {
        let items = matches
        let pagination = ReadingPagination(total:items.count,page:page,size:20)
        VStack(alignment:.leading,spacing:10) {
            Text("阅读历史独立保存，打开文件不会自动加入书架。").font(.caption)
            TextField("搜索阅读过的文件",text:$query)
            PanelRow {
                Button(query.isEmpty ? "全选" : "全选搜索结果") { selected = Set(items.map(\.id)) }.disabled(items.isEmpty)
                Button("取消选择") { selected.removeAll() }.disabled(selected.isEmpty)
                Button("删除所选历史…",role:.destructive) { confirmRemoval = true }.disabled(selected.isEmpty)
                if !selected.isEmpty { Text("已选 \(selected.count) 条").font(.caption).foregroundStyle(.secondary) }
            }
            List(Array(items[pagination.range])) { item in
                HStack {
                    Toggle("选择 "+item.title,isOn:Binding(get:{selected.contains(item.id)},set:{ value in
                        if value { selected.insert(item.id) } else { selected.remove(item.id) }
                    })).labelsHidden().help("选择 "+item.title)
                    VStack(alignment:.leading) {
                        Text(item.title).lineLimit(1).help(item.title+"\n"+item.path)
                        Text("读到第 \(item.progress.last+1) 页").font(.caption)
                    }
                    Spacer()
                    Button("继续阅读") {
                        do {
                            try store.openLibraryBook(LibraryBook(path:item.path,title:item.title,bookmark:item.progress.bookmark))
                            store.showReadingHistory = false
                        } catch { message = error.localizedDescription }
                    }.buttonStyle(.borderless)
                    Button("加入书架") {
                        Task {
                            do { try await store.library.addInBackground([URL(fileURLWithPath:item.path)]);message = "已手动加入书架" }
                            catch { message = error.localizedDescription }
                        }
                    }.buttonStyle(.borderless)
                }
            }
            HStack {
                Text("共 \(items.count) 本")
                Spacer()
                Button("上一页") { page = max(0,pagination.index-1) }.disabled(pagination.index == 0)
                Text(pagination.label)
                Button("下一页") { page = pagination.index+1 }.disabled(pagination.index >= pagination.last)
            }
            PanelRow {
                if !message.isEmpty { Text(message).font(.caption) }
                if !removed.isEmpty {
                    Button("撤销删除") {
                        ReadingProgress.setHistoryRemoved(removed,removed:false,defaults:store.readingDefaults)
                        removed.removeAll()
                        message = "已恢复历史记录"
                        revision = UUID()
                    }
                }
            }
        }
        .task(id:revision) {
            let snapshot = store.readingDefaults.dictionaryRepresentation()
            let values = await Task.detached(priority:.utility) { ReadingProgress.history(snapshot:snapshot) }.value
            guard !Task.isCancelled else { return }
            history = values
            selected.formIntersection(values.map(\.id))
        }
        .onChange(of:query) { _,_ in page = 0;selected.removeAll() }
        .confirmationDialog("删除所选的 \(selected.count) 条阅读历史？",isPresented:$confirmRemoval,titleVisibility:.visible) {
            Button("删除 \(selected.count) 条历史",role:.destructive) {
                removed = selected
                ReadingProgress.setHistoryRemoved(removed,removed:true,defaults:store.readingDefaults)
                history.removeAll{removed.contains($0.id)}
                selected.removeAll()
                page = min(page,max(0,(matches.count-1)/20))
                message = "已删除 \(removed.count) 条阅读历史"
                revision = UUID()
            }
            Button("取消",role:.cancel) {}
        } message: { Text("原文件、书架、笔记与续读位置都会保留。") }
    }
}
