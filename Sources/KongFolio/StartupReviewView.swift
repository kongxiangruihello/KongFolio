import SwiftUI

struct StartupReviewView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("上次退出未完成，请逐本恢复").font(.headline)
            Text("先恢复需要的书籍。原件与恢复副本均保留；曾中断打开的文件单独提示，不自动再次载入。")
            ScrollView {
                ForEach(store.startupEntries,id:\.slot) { entry in
                    HStack {
                        VStack(alignment:.leading) { Text(entry.path.map { URL(fileURLWithPath:$0).lastPathComponent } ?? "未保存文档"); if let path = entry.path, let count = store.startupSuspects[path] { Text("打开中断 \(count) 次，请优先检查文件").foregroundStyle(.orange) } }
                        Spacer(); Button("恢复这一本") { do { try store.restoreStartup(entry) } catch { message = error.localizedDescription } }
                    }.padding(.vertical,4)
                }
            }
            Text(message).foregroundStyle(.red)
            HStack { Button("稍后恢复") { store.deferStartupReview() }; Button("本次不恢复，保留副本") { do { try store.skipStartupEntries() } catch { message = error.localizedDescription } } }
        }.padding(20).adaptiveSheet(width:700,height:500)
    }
}
