import SwiftUI

struct ReadingHistoryOnlyView: View {
    @ObservedObject var store:WorkspaceStore
    @State private var history:[ReadingProgress.HistoryItem] = []
    @State private var query = ""
    @State private var page = 0
    @State private var message = ""
    private var matches:[ReadingProgress.HistoryItem] { history.filter{query.isEmpty || ($0.title+$0.path).localizedCaseInsensitiveContains(query)} }
    private var lastPage:Int { max(0,(matches.count-1)/20) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("阅读历史独立保存，打开文件不会自动加入书架。").font(.caption)
            TextField("搜索阅读过的文件",text:$query)
            List(Array(matches.dropFirst(min(page,lastPage)*20).prefix(20))) { item in
                HStack {
                    VStack(alignment:.leading) { Text(item.title).lineLimit(1).help(item.title+"\n"+item.path); Text("读到第 \(item.progress.last+1) 页").font(.caption) }
                    Spacer()
                    Button("继续阅读") { do { try store.openLibraryBook(LibraryBook(path:item.path,title:item.title,bookmark:item.progress.bookmark)); store.showReadingHistory = false } catch { message = error.localizedDescription } }
                    Button("加入书架") { do { try store.library.add([URL(fileURLWithPath:item.path)]); message = "已手动加入书架" } catch { message = error.localizedDescription } }
                }
            }
            HStack { Text("共 \(matches.count) 本"); Spacer(); Button("上一页") { page = max(0,page-1) }.disabled(page == 0); Text("\(min(page,lastPage)+1)/\(lastPage+1)"); Button("下一页") { page += 1 }.disabled(page >= lastPage) }
            Text(message).font(.caption)
        }.task { let snapshot = store.readingDefaults.dictionaryRepresentation(); let items = await Task.detached(priority:.utility) { ReadingProgress.history(snapshot:snapshot) }.value; guard !Task.isCancelled else { return }; history = items }.onChange(of:query) { _,_ in page = 0 }
    }
}
