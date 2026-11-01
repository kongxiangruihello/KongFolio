import SwiftUI
import UniformTypeIdentifiers

struct ReadingExportPane: View {
    enum Scope:String,CaseIterable { case selected = "所选记录", book = "当前书的全部记录", essay = "当前札记" }
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @StateObject private var controller = ReadingExportController()
    @State private var scope = Scope.selected
    @State private var preferences = ReadingExportPreferences.load()
    private var format:ReadingRecordExport.Format { preferences.format }
    private var snapshot:ReadingExportSnapshot {
        if scope == .essay, let essay = journal.essay(journal.currentEssayID), journal.draftEssay?.id != essay.id, essay.hasContent { return ReadingExportSnapshot(title:essay.title,essay:essay,options:preferences.options) }
        let ids = store.readingRecordSelection.isEmpty ? Set(store.readingRecordID.map { [$0] } ?? []) : store.readingRecordSelection
        let records = journal.state.records.filter { record in
            record.hasContent && record.removed == nil && (scope == .selected ? ids.contains(record.id) : (scope == .book && record.citations.contains{$0.source.path == store.commandWorkspace?.readingJournalPath}))
        }.sorted { $0.created < $1.created }
        return ReadingExportSnapshot(title:scope == .book ? (store.commandWorkspace?.title ?? "阅读记录")+" · 阅读笔记" : "摘录与笔记",records:records,options:preferences.options)
    }
    private var empty:Bool { snapshot.records.isEmpty && snapshot.essay == nil }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("导出范围",selection:$scope) { ForEach(Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            Picker("导出格式",selection:$preferences.format) { ForEach(ReadingRecordExport.Format.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            HStack {
                Picker("字体",selection:$preferences.options.fontName) { Text("宋体").tag("Songti SC"); Text("苹方").tag("PingFang SC"); Text("Times New Roman").tag("Times New Roman") }
                Stepper("字号 \(Int(preferences.options.fontSize))",value:$preferences.options.fontSize,in:8...36,step:1)
            }
            HStack { Toggle("原文（含图片）",isOn:$preferences.options.includeQuote); Toggle("我的笔记／论述",isOn:$preferences.options.includeNote); Toggle("出处",isOn:$preferences.options.includeSources) }
            Text("这些设置会自动记住。Markdown 保留内容选项；字体用于 Word 和 PDF。").font(.caption).foregroundStyle(.secondary)
            Text("原文、自己的笔记、图片与出处分别排版；返回原文以可点击的短文字显示。Markdown 图片放在同名配套目录中。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("刷新 Word 预览") { controller.preview(snapshot,assets:journal.folder.appendingPathComponent("Assets")) }.disabled(empty || !preferences.options.valid || controller.busy)
                Button("导出文件…",action:export).disabled(empty || !preferences.options.valid || controller.busy || (format == .word && controller.previewDigest != snapshot.digest))
                if controller.busy { ProgressView().controlSize(.small); Button("取消") { controller.cancel() } }
            }
            if let file = controller.previewURL { AcademicFilePreview(url:file).frame(minHeight:260,maxHeight:.infinity) }
            else { Text(format == .word ? "先生成实际 Word 文件预览，核对内容和出处后导出。" : "可直接导出，也可先查看 Word 排版预览。").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
            if controller.previewURL != nil && controller.previewDigest != snapshot.digest { Text("记录已更改，请刷新预览后导出 Word。").foregroundStyle(.orange) }
            Text(controller.message).font(.caption).textSelection(.enabled)
        }.onAppear { scope = store.readingExportEssay ? .essay : ((store.readingRecordID != nil || !store.readingRecordSelection.isEmpty) ? .selected : .book) }
        .onDisappear { controller.cancel() }.onChange(of:preferences) { _,value in value.save() }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:format.ext) ?? .data]
        panel.directoryURL = preferences.directoryURL
        panel.nameFieldStringValue = String(snapshot.title.prefix(80)).replacingOccurrences(of:"/",with:"-")+"."+format.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.directoryPath = url.deletingLastPathComponent().path; preferences.save()
        let value = snapshot, kind = format, assets = journal.folder.appendingPathComponent("Assets"), model = journal, presenter = controller
        do {
            let baseline = try FileBaseline.capture(url)
            Task { do { try await model.flush(); presenter.export(value,format:kind,assets:assets,to:url,expected:baseline) } catch { presenter.message = error.localizedDescription } }
        } catch { controller.message = error.localizedDescription }
    }
}
