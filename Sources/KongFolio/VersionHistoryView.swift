import SwiftUI
import PDFKit

struct VersionHistoryView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [HistoryEntry] = []
    @State private var selected: UUID?
    @State private var archive: ProjectArchive?
    @State private var preview: PDFDocument?
    @State private var message = ""
    private var entry: HistoryEntry? { entries.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing:12) {
            Text("保存历史与恢复").font(.title2.bold())
            Text(workspace.displayPath ?? "").font(.caption).textSelection(.enabled)
            HSplitView {
                List(entries, selection:$selected) { item in
                    VStack(alignment:.leading,spacing:4) {
                        Text(item.created,format:.dateTime.month().day().hour().minute().second())
                        Text("\(item.label) · \(item.pages) 页").font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }.frame(minWidth:230)
                VStack {
                    if let page = preview?.page(at:0) {
                        Image(nsImage:page.thumbnail(of:CGSize(width:320,height:350),for:.cropBox)).resizable().scaledToFit()
                        Text("预览第一页，共 \(entry?.pages ?? 0) 页").font(.caption)
                    } else { Text(entries.isEmpty ? "尚无历史；首次覆盖保存前会自动保留原件。" : "选择一个版本查看预览").foregroundStyle(.secondary) }
                }.frame(minWidth:300,maxWidth:.infinity,maxHeight:.infinity)
            }
            Text("每个文件保留最近 10 个版本，约 512 MB；大文件至少保留 2 个版本。60 秒内的连续自动保存合并，恢复前会先保存当前工作。恢复将写回当前文件，也可用撤销返回。").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("恢复选中版本") { if let entry, workspace.restoreVersion(entry) { dismiss() } else { message = workspace.error ?? "无法恢复" } }
                    .disabled(entry == nil || archive == nil || workspace.busy).buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width:700,height:550)
        .onAppear { if let source=workspace.historySource { do { entries=try DocumentHistory.list(source:source,storage:workspace.storage) } catch { message=error.localizedDescription } } }
        .onChange(of:selected) { _, _ in
            archive=nil;preview=nil
            if let entry, let source=workspace.historySource { do { archive=try DocumentHistory.read(entry,source:source,storage:workspace.storage);preview=archive.flatMap { PDFDocument(data:$0.pdf) };message="" } catch { message=error.localizedDescription } }
        }
    }
}
