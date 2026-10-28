import SwiftUI

struct ReadingHistorySheet: View {
    @ObservedObject var store: WorkspaceStore
    @State private var items: [ReadingProgress.HistoryItem] = []
    @State private var query = ""
    @State private var message = ""
    private var filtered: [ReadingProgress.HistoryItem] { items.filter { query.isEmpty || ($0.title + $0.path).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow { Text("阅读记录").font(.headline); Spacer(); Button("完成") { store.showReadingHistory = false }.keyboardShortcut(.cancelAction) }
            Text("自动记住每本书的页码、页面位置、缩放和阅读布局，关闭文档或退出后继续保留。").font(.callout).foregroundStyle(.secondary)
            TextField("搜索书名或路径", text: $query).textFieldStyle(.roundedBorder)
            if filtered.isEmpty { Text(items.isEmpty ? "还没有阅读记录。打开一本书后会自动记录。" : "没有匹配的书籍。").foregroundStyle(.secondary); Spacer() }
            else {
                List(filtered.prefix(500)) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text("上次读到第 \(item.progress.last + 1) 页" + (item.progress.pages > 0 ? " / 共 \(item.progress.pages) 页" : ""))
                            if let date = item.progress.date { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                            Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("继续阅读") {
                            do {
                                let shortcut = ReadingShortcut(path: item.path, title: item.title, position: item.progress.resumePosition(pageCount: max(item.progress.pages,item.progress.last+1)) ?? ViewPosition(selection: item.progress.last), layout: item.progress.layout, bookmark: item.progress.bookmark)
                                try store.openReadingShortcut(shortcut); store.showReadingHistory = false
                            } catch { message = error.localizedDescription }
                        }
                    }.padding(.vertical, 4)
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }.padding().adaptiveSheet(width: 720, height: 530, minimumWidth: 360)
        .onAppear { store.commandWorkspace?.saveReadingRecord(); items = ReadingProgress.history(defaults: store.readingDefaults) }
    }
}
