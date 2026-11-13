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
                Text("最近批阅").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if entries.isEmpty {
                ContentUnavailableView("还没有批阅记录",systemImage:"books.vertical",description:Text("一次打开多份 PDF 或 KongFolio 项目后，就能在这里接着读。"))
            } else {
                Picker("批次",selection:Binding(
                    get:{ store.readingBatch?.id },
                    set:{ store.selectedReadingBatchID = $0 }
                )) {
                    ForEach(Array(store.readingBatches.enumerated()),id:\.element.id) { index,batch in
                        Text(batchLabel(batch,index:index)).tag(batch.id)
                    }
                }
                HStack {
                    Text("共 \(entries.count) 份 · 已读完 \(store.readingBatch?.finishedCount ?? 0) 份 · 待读 \(store.readingBatch?.pendingCount ?? 0) 份").foregroundStyle(.secondary)
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
            .onChange(of:store.readingBatch?.id) { _,_ in page = 0 }
    }

    private func batchLabel(_ batch:ReadingOpenBatch,index:Int) -> String {
        let time = batch.created?.formatted(date:.abbreviated,time:.shortened) ?? "旧批次"
        let first = batch.entries.first?.title ?? ""
        return "\(index+1). \(time) · \(first) · \(batch.entries.count) 份"
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
