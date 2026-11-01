import SwiftUI
import Combine

struct ReadingOutputReviewView: View {
    @ObservedObject var store:WorkspaceStore
    let snapshot:ReadingExportSnapshot
    let assets:URL
    @Environment(\.dismiss) private var dismiss
    @State private var issues:[ReadingOutputIssue] = []
    @State private var busy = true
    @State private var message = "正在核对图片、出处与原文页码…"
    @State private var page = 0
    private var pagination:ReadingPagination { ReadingPagination(total:issues.count,page:page,size:10) }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("导出前完整性检查").font(.headline);Spacer();Button("关闭") { dismiss() } }
            Text("检查当前勾选的 \(snapshot.orderedItems.count) 项。版本和印刷页码缺失是提醒，可按研究需要补充；不会自动改写记录。").font(.caption)
            if busy { ProgressView() }
            Text(message).font(.caption)
            List(Array(issues.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { issue in
                HStack { VStack(alignment:.leading) { Text(issue.title).lineLimit(1).help(issue.title);Text(issue.message).font(.caption).foregroundStyle(.orange) };Spacer();Button("定位修正") { dismiss();DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { store.openReadingItem(issue.item) } } }
            }
            HStack { Text(pagination.label);Button("上一页") { page = max(0,page-1) }.disabled(pagination.index == 0);Button("下一页") { page += 1 }.disabled(pagination.index>=pagination.last) }
        }.padding(20).adaptiveSheet(width:720,height:500)
        .task { do { let result = try await ReadingOutputReview.shared.inspect(snapshot,assets:assets);try Task.checkCancellation();issues = result;message = result.isEmpty ? "本次检查未发现问题；请继续核对正文与出处内容" : "发现 \(result.count) 条需要核对的信息" } catch { message = FolioCancellation.matches(error) ? "检查已取消" : error.localizedDescription };busy = false }
    }
}
struct ReadingIncrementalExportView: View {
    @ObservedObject var journal:ReadingJournal
    @ObservedObject var controller:ReadingIncrementalController
    var options:ReadingExportOptions
    @Environment(\.dismiss) private var dismiss
    @State private var ledger:ReadingExportLedger?
    @State private var delta:ReadingExportDelta?
    @State private var expected:ReadingJournalState?
    @State private var message = ""
    @State private var formats:[ReadingRecordExport.Format] = [.word,.pdf,.markdown]
    @State private var loading = false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("增量导出阅读资料").font(.headline);Spacer();Button("关闭") { dismiss() } }
            Text("范围为整个阅读资料库。只导出自上次成功增量导出后的新增、修改内容，并另附删除清单。普通导出不改变此基准。").font(.caption)
            HStack { ForEach(ReadingRecordExport.Format.allCases,id:\.self) { kind in Toggle(kind.rawValue,isOn:Binding(get:{formats.contains(kind)},set:{if $0 { if !formats.contains(kind) { formats.append(kind) } } else { formats.removeAll{$0 == kind} }})) } }
            if let delta { ScrollView { Text(delta.report).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) } }
            HStack { Button("刷新变更清单") { Task { await refresh() } }.disabled(controller.busy || loading);Button("选择目录并导出…",action:export).disabled(controller.busy || loading || delta?.hasChanges != true || formats.isEmpty || !options.valid || journal.unreadable);if controller.busy { ProgressView().controlSize(.small);Button("取消") { controller.cancel() } } }
            if let folder = controller.folder { Button("打开上次导出目录") { NSWorkspace.shared.open(folder) } }
            Text(message).font(.caption).foregroundStyle(.orange);Text(controller.message).font(.caption).textSelection(.enabled)
        }.padding(20).adaptiveSheet(width:720,height:570)
        .task { await refresh() }.onChange(of:controller.busy) { before,after in if before && !after { Task { await refresh() } } }
    }
    private func refresh() async {
        loading = true;let folder = journal.folder
        do { let previous = try await Task.detached(priority:.utility) { try ReadingExportLedger.load(folder) }.value;try Task.checkCancellation();let value = journal.state;ledger = previous;delta = try ReadingExportDelta(value,old:previous);expected = value;message = "" } catch { message = error.localizedDescription;delta = nil;expected = nil };loading = false
    }
    private func export() {
        guard let expected,journal.state == expected else { message = "内容刚有变化，请刷新清单后导出";return }
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.canCreateDirectories = true;panel.message = "选择保存位置，将新建独立的增量导出目录"
        guard panel.runModal() == .OK,let parent = panel.url else { return }
        guard journal.state == expected else { message = "内容已变化，请刷新清单";return }
        let baseline = ledger,options = options,formats = formats
        Task { do { try await journal.flush();guard journal.state == expected else { throw FolioError(message:"内容已变化，请刷新清单") };controller.start(expected,old:baseline,options:options,formats:formats,assets:journal.folder.appendingPathComponent("Assets"),journalFolder:journal.folder,parent:parent) } catch { message = error.localizedDescription } }
    }
}
