import SwiftUI

struct ReadingOpenBatchView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        let entries = store.readingBatch?.entries ?? []
        let pagination = ReadingPagination(total:entries.count,page:page,size:10)
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("上次批阅").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if entries.isEmpty {
                ContentUnavailableView("还没有批阅记录",systemImage:"books.vertical",description:Text("一次打开多份 PDF 或 KongFolio 项目后，就能在这里接着读。"))
            } else {
                HStack {
                    Text("共 \(entries.count) 份 · 已读完 \(entries.filter{$0.status == .finished}.count) 份").foregroundStyle(.secondary)
                    Spacer()
                    Button("继续批阅") { store.resumeReadingBatch(); dismiss() }
                        .buttonStyle(.borderedProminent).disabled(store.readingBatch?.next == nil)
                }
                List(Array(entries[pagination.range])) { entry in row(entry) }
                HStack {
                    Button("上一页") { page -= 1 }.disabled(pagination.index == 0)
                    Text(pagination.label)
                    Button("下一页") { page += 1 }.disabled(pagination.index >= pagination.last)
                }.font(.caption)
            }
        }.padding(20).adaptiveSheet(width:660,height:550,minimumWidth:360)
            .onChange(of:entries.count) { _,_ in page = pagination.index }
    }

    private func row(_ entry:ReadingOpenBatch.Entry) -> some View {
        HStack {
            VStack(alignment:.leading,spacing:3) {
                Text(entry.title).lineLimit(1).help(entry.path)
                Text(entry.status.rawValue+(entry.position.map{" · 第 \($0.selection+1) 页"} ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let message = entry.message,entry.status != .finished {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu("操作") {
                Button(entry.status == .failed ? "重试" : "打开文献") { store.openReadingBatchEntry(entry); dismiss() }
                if entry.status == .failed || entry.status == .skipped {
                    Button("重新定位…") { store.locateReadingBatchEntry(entry) }
                }
                if entry.status == .pending || entry.status == .failed {
                    Button("稍后处理") { store.skipReadingBatchEntry(entry) }
                }
                if entry.status == .finished || entry.status == .skipped {
                    Button("标为待读") { store.updateBatchEntry(entry.id) { $0.status = .pending; $0.message = nil } }
                }
            }.fixedSize()
        }.padding(.vertical,3)
    }
}
