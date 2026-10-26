import SwiftUI
import PDFKit

struct VersionHistoryView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var entries:[HistoryEntry]=[]
    @State private var selected:UUID?
    @State private var compareTo:UUID?
    @State private var before:PDFDocument?
    @State private var after:PDFDocument?
    @State private var rows:[PageDifference]=[]
    @State private var page=0
    @State private var working=false
    @State private var message=""
    @State private var loadedRevision:UUID?
    private var entry:HistoryEntry? { entries.first { $0.id==selected } }
    private var row:PageDifference? { rows.first { $0.id==page } }
    private var key:String { "\(selected?.uuidString ?? "")-\(compareTo?.uuidString ?? "current")-\(workspace.revision)" }
    struct Loaded { var before:Data;var after:Data;var rows:[PageDifference] }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("保存历史、比较与恢复").font(.title2.bold())
            Text(workspace.displayPath ?? "").font(.caption).textSelection(.enabled)
            HStack {
                Picker("历史版本",selection:$selected) {
                    Text("请选择版本").tag(nil as UUID?)
                    ForEach(entries) { Text(label($0)).tag($0.id as UUID?) }
                }
                Picker("对照",selection:$compareTo) {
                    Text("当前工作（含未保存编辑）").tag(nil as UUID?)
                    ForEach(entries) { Text(label($0)).tag($0.id as UUID?) }
                }
            }
            if working { ProgressView("正在逐页检查差异…");Spacer() }
            else if let before,let after {
                Text("\(rows.filter(\.changed).count) 处页面差异 · 左 \(before.pageCount) 页 / 右 \(after.pageCount) 页").font(.caption)
                ComparisonViewer(before:before,after:after,rows:rows,leftTitle:"选中历史版本",rightTitle:compareTo == nil ? "当前工作" : "对照历史版本",selection:$page)
            } else { Spacer();Text(entries.isEmpty ? "尚无历史；首次覆盖保存前会自动保留原件。" : "选择历史版本，检查各页变化。").foregroundStyle(.secondary);Spacer() }
            Text("图像差异采用缩略图检测，细微变化请放大核对；文字、旋转、裁边和批注另行比较。移动页可能显示为删除与新增。每文件最多 10 个版本、约 512 MB，至少保留 2 个。恢复前保留当前工作，恢复后写回文件。").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("仅恢复左侧这一页") {
                    if let entry,let old=row?.before,let current=row?.after,workspace.restoreHistoryPage(entry,page:old,replacing:current) { dismiss() }
                    else { message=workspace.error ?? "无法恢复这一页" }
                }.disabled(working || compareTo != nil || row?.before == nil || row?.after == nil || loadedRevision != workspace.revision || workspace.busy)
                Button("恢复整个选中版本") {
                    if let entry,workspace.restoreVersion(entry) { dismiss() } else { message=workspace.error ?? "无法恢复" }
                }.disabled(entry == nil || before == nil || working || workspace.busy).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width:1100,height:760)
        .onAppear {
            if let source=workspace.historySource {
                do { entries=try DocumentHistory.list(source:source,storage:workspace.storage);selected=entries.first?.id }
                catch { message=error.localizedDescription }
            }
        }
        .task(id:key) { await load() }
    }
    private func label(_ entry:HistoryEntry) -> String { entry.created.formatted(date:.abbreviated,time:.standard)+" · "+entry.label+" · \(entry.pages) 页" }
    private func load() async {
        before=nil;after=nil;rows=[];loadedRevision=nil
        guard let entry,let source=workspace.historySource else { working=false;return }
        let storage=workspace.storage,other=entries.first { $0.id==compareTo },revision=workspace.revision
        do {
            let current=other == nil ? try workspace.pdfData() : Data()
            working=true;message=""
            let worker=Task.detached(priority:.userInitiated) {
                let left=try DocumentHistory.read(entry,source:source,storage:storage).pdf
                let right=try other.map { try DocumentHistory.read($0,source:source,storage:storage).pdf } ?? current
                return Loaded(before:left,after:right,rows:try PDFComparison.compare(left,right))
            }
            let result=try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
            try Task.checkCancellation()
            before=PDFDocument(data:result.before);after=PDFDocument(data:result.after);rows=result.rows;page=result.rows.first(where:{$0.changed})?.id ?? 0;loadedRevision=revision;working=false
        } catch is CancellationError { }
        catch { if !Task.isCancelled { message=error.localizedDescription;working=false } }
    }
}
