import SwiftUI

struct DocumentSaveDetails: View {
    @ObservedObject var workspace:Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var retrying = false
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("保存状态").font(.headline)
            Text(workspace.displayName).textSelection(.enabled)
            Text(workspace.saving ? "正在保存文件与阅读资料…" : (workspace.dirty ? "仍有修改等待保存" : "当前文件没有待保存修改"))
            if let date = workspace.lastVerifiedDocumentSave { Text("本次打开后最近成功保存："+date.formatted(date:.numeric,time:.standard)).font(.caption) }
            if let path = workspace.historySource?.path { Text(path).font(.caption).textSelection(.enabled) }
            Text(workspace.recoveryStatus).font(.caption).foregroundStyle(.secondary)
            if workspace.saveConflict { Text("原文件已被其他程序修改，请回到阅读窗口处理冲突或另存副本。").foregroundStyle(.orange) }
            if let error = workspace.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(workspace.error == nil ? "立即保存" : "重试保存") {
                    if workspace.historySource == nil {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { workspace.saveDirectly() }
                    } else {
                        retrying = true
                        Task {
                            _ = await workspace.saveInBackground(automatic:false,includePrivateData:true)
                            retrying = false
                        }
                    }
                }.disabled(retrying || workspace.busy || workspace.saving || workspace.saveConflict)
                Button("另存副本…") { workspace.saveProject(asNew:true) }.disabled(workspace.busy || workspace.saving)
                Spacer();Button("关闭") { dismiss() }
            }
        }.padding(20).adaptiveSheet(width:620,height:340,minimumWidth:380)
    }
}
struct ReadingQuoteCorrectionView: View {
    @ObservedObject var journal:ReadingJournal
    let record:ReadingRecord
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = WritingSession()
    @State private var text = ""
    @State private var script = ReadingQuoteTools.Script.unchanged
    @State private var joinLines = false
    @State private var compactSpaces = false
    @State private var typo = ""
    @State private var replacement = ""
    @State private var message = ""
    @State private var expected:ReadingRecord?
    @State private var differences:QuoteProofreading?
    @State private var active = 0
    @State private var cleanup:QuoteProofreading?
    @State private var checked = Set<Int>()
    @State private var preparing = false
    @State private var cleanupTask:Task<Void,Never>?
    private var original:String { record.originalQuote ?? record.originalOCR ?? record.quote }
    private var change:QuoteProofreading.Change? {
        guard let differences, differences.revised == text, differences.changes.indices.contains(active) else { return nil }
        return differences.changes[active]
    }

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("摘录原文与校订对照").font(.headline)
            HStack {
                Button("上一处",systemImage:"chevron.left") { active -= 1 }.disabled(change == nil || active == 0)
                Text(change == nil ? (text == original ? "与原文一致" : "正在对照…") : "第 \(active+1) / \(differences?.changes.count ?? 0) 处")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button("下一处",systemImage:"chevron.right") { active += 1 }.disabled(change == nil || active+1 >= (differences?.changes.count ?? 0))
                Spacer()
                Button(differences?.coarse == true ? "恢复差异区段" : "恢复这一处原文",action:restoreChange).disabled(change == nil)
            }.font(.callout)
            HSplitView {
                VStack(alignment:.leading,spacing:6) {
                    Text("最初摘录").font(.caption.weight(.semibold))
                    if let change { differenceText(change.original,empty:"原文无此处文字",color:.orange) }
                    ScrollView { Text(original).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }
                }.frame(minWidth:180)
                VStack(alignment:.leading,spacing:6) {
                    Text("校订文字").font(.caption.weight(.semibold))
                    if let change { differenceText(change.revised,empty:"此处文字已删除",color:.blue) }
                    StableTextEditor(text:$text,label:"摘录校订对照正文",identity:"correction:"+record.id.uuidString,session:session)
                }.frame(minWidth:220)
            }.frame(minHeight:250)
            Divider()
            HStack {
                Picker("字形",selection:$script) { ForEach(ReadingQuoteTools.Script.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Toggle("合并段内断行",isOn:$joinLines)
                Toggle("清理空格",isOn:$compactSpaces)
            }.controlSize(.small)
            HStack {
                TextField("查找 OCR 错字（可留空）",text:$typo)
                TextField("替换为",text:$replacement)
                Button("预览整理…",action:previewCleanup)
                    .disabled(preparing || (script == .unchanged && !joinLines && !compactSpaces && typo.isEmpty))
                if preparing { ProgressView().controlSize(.small) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("采用校订") {
                    guard let expected else { return }
                    do { try journal.applyQuoteCorrection(expected,text:text);dismiss() }
                    catch { message = error.localizedDescription }
                }.disabled(expected == nil)
            }
        }.padding(20).adaptiveSheet(width:860,height:630,minimumWidth:540)
        .onAppear { expected = journal.record(record.id);text = expected?.quote ?? record.quote }
        .onDisappear { cleanupTask?.cancel() }
        .task(id:text) {
            do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
            let before = original, after = text
            let job = Task.detached { try QuoteProofreading(original:before,revised:after) }
            let result = await withTaskCancellationHandler { try? await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled, after == text else { return }
            differences = result
            active = min(active,max(0,(result?.changes.count ?? 0)-1))
        }
        .sheet(isPresented:Binding(get:{cleanup != nil},set:{if !$0 { cleanup = nil }})) {
            if let cleanup { cleanupSheet(cleanup) }
        }
    }

    private func differenceText(_ value:String,empty:String,color:Color) -> some View {
        Text(value.isEmpty ? empty : value)
            .font(.callout.weight(.medium)).lineLimit(3)
            .frame(maxWidth:.infinity,minHeight:28,alignment:.leading)
            .padding(6).background(color.opacity(0.15),in:RoundedRectangle(cornerRadius:5))
    }

    private func replace(_ range:NSRange, with value:String) {
        guard let view = session.view, view.string == text, !view.hasMarkedText() else { return }
        WritingEdit.apply(TextEdit(range:range,replacement:value,
                                    selection:NSRange(location:range.location,length:value.utf16.count)),to:view)
    }

    private func restoreChange() {
        guard let change else { return }
        replace(change.revisedRange,with:change.original)
    }

    private func previewCleanup() {
        let source = text, script = script, typo = typo, replacement = replacement
        let options = WritingCleanup(joinLines:joinLines,compactSpaces:compactSpaces)
        preparing = true
        message = ""
        cleanupTask = Task {
            let job = Task.detached {
                var candidate = ReadingQuoteTools.preview(options.apply(source),script:script,joinLines:false)
                if !typo.isEmpty { candidate = candidate.replacingOccurrences(of:typo,with:replacement) }
                return try QuoteProofreading(original:source,revised:candidate)
            }
            let preview = await withTaskCancellationHandler { try? await job.value } onCancel: { job.cancel() }
            preparing = false
            guard !Task.isCancelled, let preview else { return }
            guard source == text else { message = "正文已变化，请重新预览";return }
            if preview.changes.isEmpty { message = "没有需要整理的文字";return }
            checked = []
            cleanup = preview
        }
    }

    private func cleanupSheet(_ plan:QuoteProofreading) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text("勾选要采用的整理结果").font(.headline)
            if plan.coarse { Text("差异较长，预览已合并为一个区段。").font(.caption) }
            List(plan.changes) { change in
                Toggle(isOn:Binding(get:{checked.contains(change.id)},set:{ on in
                    if on { checked.insert(change.id) } else { checked.remove(change.id) }
                })) {
                    HStack {
                        differenceText(change.original.debugDescription,empty:"无",color:.orange)
                        Image(systemName:"arrow.right")
                        differenceText(change.revised.debugDescription,empty:"无",color:.blue)
                    }
                }
            }
            HStack {
                Button("全选") { checked = Set(plan.changes.map(\.id)) }
                Spacer()
                Button("取消") { cleanup = nil }
                Button("采用选中项") {
                    guard text == plan.original else { return }
                    replace(NSRange(location:0,length:text.utf16.count),with:plan.applying(checked))
                    cleanup = nil
                }.disabled(checked.isEmpty)
            }
        }.padding(20).adaptiveSheet(width:700,height:450,minimumWidth:460)
    }
}
