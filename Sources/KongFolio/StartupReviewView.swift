import SwiftUI

struct StartupReviewView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("选择需要恢复的文献").font(.headline)
            Text("按需恢复需要的书籍。原件与恢复副本均保留；曾中断打开的文件单独提示，不自动再次载入。")
            ScrollView {
                ForEach(store.startupEntries,id:\.slot) { entry in
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(entry.path.map { URL(fileURLWithPath:$0).lastPathComponent } ?? "未保存文档")
                                .lineLimit(1).help(entry.path ?? "")
                            HStack {
                                if store.pendingStartupSelected == entry.slot { Text("上次正在阅读") }
                                if let page = store.startupPage(entry) { Text("PDF 第 \(page) 页") }
                                let interrupted = store.startupInterruptionCount(entry)
                                if interrupted > 0 { Text("待重试 · 打开中断 \(interrupted) 次").foregroundStyle(.orange) }
                            }.font(.caption)
                        }
                        Spacer()
                        Button(store.startupInterruptionCount(entry) > 0 ? "重试打开" : "恢复这一本") {
                            do { try store.restoreStartup(entry) } catch { message = error.localizedDescription }
                        }
                    }.padding(.vertical,4)
                }
            }
            Text(message).foregroundStyle(.red)
            HStack { Button("稍后恢复") { store.deferStartupReview() }; Button("本次不恢复，保留副本") { do { try store.skipStartupEntries() } catch { message = error.localizedDescription } } }
        }.padding(20).adaptiveSheet(width:700,height:500)
    }
}
