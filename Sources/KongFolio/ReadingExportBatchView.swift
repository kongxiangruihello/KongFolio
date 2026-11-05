import SwiftUI
import UniformTypeIdentifiers

struct ReadingExportBatchView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let snapshot:ReadingExportSnapshot
    @ObservedObject private var batch:ReadingExportBatch
    @ObservedObject private var package:ReadingPackageController
    @Environment(\.dismiss) private var dismiss
    @State private var formats:[ReadingRecordExport.Format] = [.word,.markdown,.pdf]
    @State private var originals = false
    @State private var message = ""
    @State private var page = 0
    init(store:WorkspaceStore,journal:ReadingJournal,snapshot:ReadingExportSnapshot) { self.store = store;self.journal = journal;self.snapshot = snapshot;batch = store.readingExportBatch;package = store.readingPackage }
    private var pagination:ReadingPagination { ReadingPagination(total:batch.jobs.count,page:page,size:10) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("批量导出与研究资料包").font(.headline);Spacer();Button("关闭") { dismiss() } }
            Text("使用刚才勾选的 \(snapshot.orderedItems.count) 项资料与当前导出设置。批量导出按原书分组，笔记单独输出。").font(.caption)
            HStack { ForEach(ReadingRecordExport.Format.allCases,id:\.self) { format in Toggle(format.rawValue,isOn:Binding(get:{formats.contains(format)},set:{if $0 { if !formats.contains(format) { formats.append(format) } } else { formats.removeAll{$0 == format} }})) } }
            HStack {
                Button("选择目录并开始批量导出…",action:startBatch).disabled(formats.isEmpty || batch.busy || package.busy)
                Button("仅重试失败／取消项") { batch.retry() }.disabled(batch.busy || !batch.jobs.contains(where:{$0.state == .failed || $0.state == .cancelled}))
                if batch.busy { Button("停止批量导出") { batch.cancel() } }
            }
            if !batch.jobs.isEmpty {
                ProgressView(value:Double(batch.completed),total:Double(max(1,batch.jobs.count)))
                Text(batch.message).font(.caption)
                List(Array(batch.jobs.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { job in
                    VStack(alignment:.leading) { Text(job.destination.lastPathComponent).lineLimit(1).help(job.destination.path);Text(job.state.rawValue+(job.message.isEmpty ? "" : " · "+job.message)).font(.caption).foregroundStyle(job.state == .failed ? Color.red : .secondary) }
                }.frame(minHeight:100,maxHeight:220)
                HStack { Text(pagination.label).font(.caption);Button("上一页") { page = max(0,page-1) }.disabled(pagination.index == 0);Button("下一页") { page += 1 }.disabled(pagination.index>=pagination.last);Spacer();if let folder = batch.folder { Button("打开导出目录") { NSWorkspace.shared.open(folder) } } }
            }
            Divider()
            Toggle("资料包包含所引用的原始文献",isOn:$originals)
            Text("默认打包阅读记录、摘录图片、出处清单和所选格式。勾选后只复制引用到的原书；不复制整个书架。解压后可通过目录页打开文献与记录。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("导出完整资料包 ZIP…",action:startPackage).disabled(formats.isEmpty || package.busy || batch.busy);if package.busy { ProgressView().controlSize(.small);Button("取消打包") { package.cancel() } } }
            Text(package.message).font(.caption).textSelection(.enabled)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            Spacer(minLength:0)
        }.padding(20).adaptiveSheet(width:780,height:640,minimumWidth:540)
    }
    private var assets:URL { journal.folder.appendingPathComponent("Assets") }
    private func startBatch() {
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.canCreateDirectories = true;panel.message = "选择输出位置；将在其中新建独立导出目录"
        guard panel.runModal() == .OK,let parent = panel.url else { return }
        let name = "KongFolio-导出-"+ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")+"-"+String(UUID().uuidString.prefix(6))
        let folder = parent.appendingPathComponent(name),formats = formats
        Task { do { try await journal.flush();batch.start(snapshot,formats:formats,assets:assets,folder:folder);page = 0 } catch { message = error.localizedDescription } }
    }
    private func startPackage() {
        let panel = NSSavePanel();panel.allowedContentTypes = [.zip];panel.nameFieldStringValue = ReadingExportJobs.filename(snapshot.title)+"-资料包.zip"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { let expected = try FileBaseline.capture(url),formats = formats,originals = originals
            Task { do { try await journal.flush();package.start(snapshot,formats:formats,assets:assets,originals:originals,to:url,expected:expected) } catch { message = error.localizedDescription } }
        } catch { message = error.localizedDescription }
    }
}
