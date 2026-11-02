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
                Button("重试保存") { retrying = true;Task { _ = await workspace.saveInBackground(automatic:false,includePrivateData:true);retrying = false } }.disabled(retrying || workspace.busy || workspace.saving || workspace.saveConflict || workspace.historySource == nil)
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
    @State private var text = ""
    @State private var script = ReadingQuoteTools.Script.unchanged
    @State private var joinLines = false
    @State private var message = ""
    @State private var expected:ReadingRecord?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("摘录原文与校订对照").font(.headline)
            Text("左侧保留最初文字；右侧编辑摘录副本。字形转换和合并断行仅在点击“生成预览”后应用，不改 PDF。").font(.caption)
            HStack { Picker("字形",selection:$script) { ForEach(ReadingQuoteTools.Script.allCases,id:\.self) { Text($0.rawValue).tag($0) } };Toggle("合并段内断行",isOn:$joinLines);Button("生成预览") { text = ReadingQuoteTools.preview(text,script:script,joinLines:joinLines) } }
            HSplitView {
                VStack(alignment:.leading) { Text("最初摘录").font(.caption);ScrollView { Text(record.originalQuote ?? record.originalOCR ?? record.quote).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) } }.frame(minWidth:180)
                VStack(alignment:.leading) { Text("校订文字").font(.caption);StableTextEditor(text:$text,label:"摘录校订对照正文",identity:"correction:"+record.id.uuidString) }.frame(minWidth:220)
            }.frame(minHeight:260)
            Text(message).font(.caption).foregroundStyle(.orange)
            HStack { Button("取消") { dismiss() };Spacer();Button("采用校订") { guard let expected else { return };do { try journal.applyQuoteCorrection(expected,text:text);dismiss() } catch { message = error.localizedDescription } }.disabled(expected == nil) }
        }.padding(20).adaptiveSheet(width:820,height:560,minimumWidth:500)
        .onAppear { expected = journal.record(record.id);text = expected?.quote ?? record.quote }
    }
}
