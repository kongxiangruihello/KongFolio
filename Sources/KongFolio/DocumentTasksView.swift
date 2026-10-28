import SwiftUI
import PDFKit

struct DocumentTasksView: View {
    @ObservedObject var queue: DocumentTaskQueue
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("后台任务").font(.title2.bold())
            Text("处理使用任务开始时的文档副本，可关闭面板继续阅读其他文件。暂停和重启会保留已完成页面；继续前核对原件版本。取消不会覆盖原件或已有输出。").font(.caption).foregroundStyle(.secondary)
            if !queue.persistenceMessage.isEmpty { Text(queue.persistenceMessage).font(.caption).foregroundStyle(.red) }
            Button("只重试失败任务") { queue.retryFailed() }.disabled(!queue.items.contains { $0.state == .failed && queue.canResume($0.id) })
            if queue.items.isEmpty { Text("暂时没有后台任务").padding(.vertical, 24) }
            ForEach(queue.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.headline)
                    if item.active { ProgressView(value: item.progress) }
                    Text(item.state.rawValue + (item.message.isEmpty ? "" : " · " + item.message)).font(.caption).textSelection(.enabled)
                    PanelRow {
                        if item.active { Button("暂停") { queue.pause(item.id) }.disabled(!queue.canPause(item.id)); Button("取消任务") { queue.cancel(item.id) }.disabled(item.state == .cancelling) }
                        if item.state == .queued { Button("取消等待") { queue.cancel(item.id) } }
                        if queue.canResume(item.id) { Button(item.state == .failed ? "重试任务" : "继续处理") { do { try queue.resume(item.id) } catch { store.present(error) } } }
                        if let file = item.file {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            if file.pathExtension == "json" {
                                Button("查看表格草稿") { for workspace in store.tabs.compactMap(\.workspace) { workspace.loadTableDrafts() }; store.pendingRecoveryURL = file; store.showBackgroundJobs = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.showRecoveryCenter = true } }
                            }
                            if file.pathExtension == "pdf" {
                                Button("打开结果") { store.showBackgroundJobs = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.openInNewTab([file]) } }
                                Button("打印结果…") { if let document = PDFDocument(url: file) { DocumentPrinting.printDocument(document) } }
                            }
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("关闭") { store.showBackgroundJobs = false }.keyboardShortcut(.cancelAction)
        }.padding(24).adaptiveSheet(width: 620, height: 620, minimumWidth: 350, flexibleHeight: true)
    }
}
struct DocumentTaskButton: View {
    @ObservedObject var queue: DocumentTaskQueue
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        Button { store.showBackgroundJobs = true } label: {
            Image(systemName: queue.running ? "clock.arrow.circlepath" : "checklist")
            if queue.running { Text("\(queue.activeCount)").font(.caption) }
        }.buttonStyle(.plain).help("后台任务：查看进度、取消处理和打开结果").padding(.horizontal, 6)
    }
}
