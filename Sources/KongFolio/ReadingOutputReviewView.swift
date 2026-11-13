import SwiftUI
import Combine

struct ReadingOutputReviewView: View {
    @ObservedObject var journal: ReadingJournal
    let snapshot: ReadingExportSnapshot
    let assets: URL
    var focusedIssue: String?
    var openItem: (ReadingLibraryID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var issues: [ReadingOutputIssue] = []
    @State private var busy = true
    @State private var message = ""
    @State private var page = 0
    @State private var editing: ReadingOutputIssue?
    @State private var positioned = false
    @State private var issuesOnly = false
    private var items: [ReadingExportItem] { snapshot.refreshed(in:journal).orderedItems }
    private var pagination: ReadingPagination {
        ReadingPagination(total:issuesOnly ? issues.count : items.count,page:page,size:10)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("导出前完整性检查").font(.headline)
                Spacer()
                Button("返回导出") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("正在核对当前勾选的 \(snapshot.orderedItems.count) 项。保存出处后会刷新检查结果。")
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.small) }
            Text(message).font(.caption)
            Picker("查看",selection:$issuesOnly) {
                Text("导出顺序与出处").tag(false)
                Text("待核对问题").tag(true)
            }.pickerStyle(.segmented)
            if issuesOnly {
                List(Array(issues[pagination.range])) { issue in issueRow(issue) }
            } else {
                let ordered = items
                let issuesByItem = Dictionary(grouping:issues,by:\.item)
                List(pagination.range,id:\.self) { index in
                    let item = ordered[index]
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text("\(index+1). "+item.title).lineLimit(1).help(item.title)
                            Spacer()
                            Button("查看记录") { openItem(item.libraryID) }
                        }
                        Text("创建 "+ReadingRecordMetadata.date(item.created)+" · 修改 "+ReadingRecordMetadata.date(item.modified))
                            .font(.caption).foregroundStyle(.secondary)
                        if snapshot.options?.includeSources != false {
                            if item.citations.isEmpty {
                                Text("未附出处").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(item.citations.enumerated()),id:\.offset) { _,citation in
                                Text(citation.display).font(.caption).textSelection(.enabled)
                            }
                        }
                        ForEach(issuesByItem[item.libraryID] ?? []) { issue in issueRow(issue) }
                    }.padding(.vertical,3)
                }
            }
            HStack {
                Text(pagination.label)
                Button("上一页") { page -= 1 }.disabled(pagination.index == 0)
                Button("下一页") { page += 1 }.disabled(pagination.index >= pagination.last)
            }
        }.padding(20).onAppear { issuesOnly = focusedIssue != nil }.adaptiveSheet(width:720,height:500,minimumWidth:360)
            .onChange(of:issuesOnly) { _,_ in page = 0 }
            .task(id:journal.revisionID) { await refresh() }
            .sheet(item:$editing) { issue in
                if let target = issue.source {
                    ReadingExportSourceEditor(journal:journal,target:target) { editing = nil }
                }
            }
    }

    private func issueRow(_ issue:ReadingOutputIssue) -> some View {
        HStack {
            VStack(alignment:.leading,spacing:4) {
                Text(issue.title).lineLimit(1).help(issue.title)
                    .fontWeight(issue.id == focusedIssue ? .semibold : .regular)
                Text(issue.message).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            if issue.source != nil {
                Button("修正出处…") { editing = issue }.disabled(journal.unreadable)
            }
            Button("查看记录") { openItem(issue.item) }
        }
    }

    private func refresh() async {
        busy = true
        let current = snapshot.refreshed(in:journal)
        do {
            let result = try await ReadingOutputReview.shared.inspect(current,assets:assets)
            try Task.checkCancellation()
            issues = result
            if !positioned,let focusedIssue,let index = result.firstIndex(where:{$0.id == focusedIssue}) {
                page = index / pagination.size
                positioned = true
            } else { page = pagination.index }
            message = result.isEmpty ? "本次检查未发现问题" : "还有 \(result.count) 条需要核对"
        } catch where FolioCancellation.matches(error) { return }
        catch { message = error.localizedDescription }
        busy = false
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
