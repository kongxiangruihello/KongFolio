import SwiftUI

struct EditorDiffRows: View {
    var hunks:[EditorDiffHunk]
    var selected:Binding<Int?>
    var body:some View {
        List(selection:selected) { ForEach(hunks) { h in
            VStack(alignment:.leading,spacing:5) {
                Text("变更 \(h.id+1)").font(.caption).bold()
                Text(h.before.isEmpty ? "（此前没有内容）" : h.before).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading).padding(6).background(.red.opacity(0.07))
                Text(h.after.isEmpty ? "（当前已删除）" : h.after).foregroundStyle(.green).frame(maxWidth:.infinity,alignment:.leading).padding(6).background(.green.opacity(0.07))
            }.font(.system(.caption,design:.monospaced)).textSelection(.enabled).tag(h.id)
        } }
    }
}
struct EditorHistoryPane: View {
    @ObservedObject var note:MarkdownNote
    let source:String
    @Environment(\.dismiss) private var dismiss
    @State private var entries:[HistoryEntry] = []
    @State private var selected:UUID?
    @State private var hunks:[EditorDiffHunk] = []
    @State private var selectedHunk:Int?
    @State private var message = ""
    @State private var loading = false
    @State private var generation = UUID()
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("红色为历史文字，绿色为当前文字。可以只恢复选中的一处；恢复前先保留当前工作，不立即覆盖磁盘文件。").font(.caption)
            Picker("历史版本",selection:$selected) { Text("选择版本").tag(nil as UUID?);ForEach(entries) { Text($0.created.formatted()+" · "+$0.label).tag($0.id as UUID?) } }
            if loading { ProgressView("正在比较…") }
            EditorDiffRows(hunks:hunks,selected:$selectedHunk)
            HStack { Text(message).font(.caption).foregroundStyle(.orange);Spacer();Button("仅恢复选中的变更") { restore() }.disabled(note.readOnly || selectedHunk == nil || loading) }
        }.onAppear { do { if let url = note.fileURL { entries = try TextVersionHistory.list(source:url,storage:note.storage);selected = entries.first?.id;load() } else { message = "文件首次保存后即可使用历史比较" } } catch { message = error.localizedDescription } }.onChange(of:selected) { _,_ in load() }
        .onDisappear { generation = UUID() }
    }
    private func load() {
        hunks = [];selectedHunk = nil;message = "";generation = UUID();let token = generation
        guard let entry = entries.first(where:{$0.id == selected}),let url = note.fileURL else { return };loading = true
        let storage = note.storage,current = source
        Task { do { let changes = try await Task.detached(priority:.utility) { let old = try TextVersionHistory.read(entry,source:url,storage:storage);return EditorDiff.hunks(old:old.text,new:current) }.value
            guard generation == token else { return };hunks = changes;loading = false;if changes.isEmpty { message = "两个版本的文字相同" }
        } catch { guard generation == token else { return };loading = false;message = error.localizedDescription } }
    }
    private func restore() {
        guard let h = hunks.first(where:{$0.id == selectedHunk}),note.text == source else { message = "正文已变化，请重新比较";return }
        do { try note.preserveBeforeTool("局部恢复前的当前工作");if note.commitEditorEdit(EditorDiff.restore(h),expected:source) { dismiss() } } catch { message = error.localizedDescription }
    }
}
struct EditorMergePane: View {
    @ObservedObject var note:MarkdownNote
    let source:String
    @Environment(\.dismiss) private var dismiss
    @State private var plan:EditorMergePlan?
    @State private var baseline:FileBaseline?
    @State private var choices:[Int:Bool] = [:]
    @State private var message = ""
    @State private var loading = false
    @State private var generation = UUID()
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("以打开或上次保存时的正文为基准。互不重叠的修改自动合并；冲突处逐项选择。采用后仍需保存，原件和当前工作均先备份。").font(.caption)
            if loading { ProgressView("正在读取与比较…") }
            ScrollView { LazyVStack(alignment:.leading,spacing:14) {
                if let plan { ForEach(plan.parts) { part in
                    VStack(alignment:.leading,spacing:5) {
                        Text("第 \(part.id+1) 处 · "+(part.conflict ? "需要选择" : "可自动合并")).bold()
                        Text("基准："+part.base).foregroundStyle(.secondary)
                        HStack(alignment:.top) { VStack(alignment:.leading) { Text("我的修改").bold();Text(part.local.isEmpty ? "（删除）" : part.local) }.frame(maxWidth:.infinity,alignment:.leading);Divider();VStack(alignment:.leading) { Text("外部修改").bold();Text(part.external.isEmpty ? "（删除）" : part.external) }.frame(maxWidth:.infinity,alignment:.leading) }
                        if part.conflict { HStack { Button(choices[part.id] == true ? "✓ 采用我的修改" : "采用我的修改") { choices[part.id] = true };Button(choices[part.id] == false ? "✓ 采用外部修改" : "采用外部修改") { choices[part.id] = false } } }
                    }.textSelection(.enabled).padding(10).background(.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius:6))
                } }
            }}
            HStack { Text(message).font(.caption).foregroundStyle(.orange);Spacer();Button("采用合并结果") { merge() }.disabled(note.readOnly || plan == nil || loading || plan?.parts.contains(where:{$0.conflict && choices[$0.id] == nil}) == true) }
        }.onAppear { load() }.onDisappear { generation = UUID() }
    }
    private func load() {
        guard let url = note.fileURL else { message = "请先保存文件";return }
        guard let base = note.baselineText else { message = "这份旧恢复稿没有可靠基准，请先另存副本，再比较外部原件";return }
        loading = true;generation = UUID();let token = generation,current = source
        Task { do {
            let result = try await Task.detached(priority:.utility) { () throws -> (EditorMergePlan,FileBaseline) in
                let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size <= 8_000_000 else { throw FolioError(message:"外部文件较大，请先另存当前工作再分拆比较") }
                let bytes = try Data(contentsOf:url),expected = try FileBaseline.capture(url,data:bytes),external = TextImport.normalized(try TextImport.decode(bytes));return (EditorMergePlan(base:base,local:current,external:external),expected)
            }.value
            guard generation == token else { return };plan = result.0;baseline = result.1;loading = false;if result.0.parts.isEmpty { message = "当前正文、磁盘原件和基准相同" }
        } catch { guard generation == token else { return };loading = false;message = error.localizedDescription } }
    }
    private func merge() {
        guard let plan,let baseline,let url = note.fileURL,note.text == source else { message = "正文已变化，请重新比较";return }
        do {
            try baseline.verify(url);let result = try plan.result(choices:choices)
            try note.preserveBeforeTool("合并外部修改前的当前工作");try TextVersionHistory.protectExisting(url,storage:note.storage)
            guard note.commitEditorEdit(TextEdit(range:NSRange(location:0,length:source.utf16.count),replacement:result,selection:NSRange(location:0,length:0)),expected:source) else { return }
            note.fileBaseline = baseline;note.baselineText = plan.external;note.saveConflict = false;note.dirty = true;try note.writeBackup();note.status = "已合并到编辑区，请核对后保存；原件与当前工作已备份";dismiss()
        } catch { message = error.localizedDescription }
    }
}
