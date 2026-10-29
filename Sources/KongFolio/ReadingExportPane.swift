import SwiftUI
import UniformTypeIdentifiers

struct ReadingExportPane: View {
    enum Scope:String,CaseIterable { case selected = "所选记录", book = "当前书的全部记录", essay = "当前札记" }
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @StateObject private var controller = ReadingExportController()
    @State private var scope = Scope.selected
    @State private var format = ReadingRecordExport.Format.word
    private var snapshot:ReadingExportSnapshot {
        if scope == .essay, let essay = journal.essay(journal.state.currentEssay) { return ReadingExportSnapshot(title:essay.title,essay:essay) }
        let ids = store.readingRecordSelection.isEmpty ? Set(store.readingRecordID.map { [$0] } ?? []) : store.readingRecordSelection
        let records = journal.state.records.filter { record in
            record.removed == nil && (scope == .selected ? ids.contains(record.id) : (scope == .book && record.citations.contains{$0.source.path == store.commandWorkspace?.readingJournalPath}))
        }.sorted { $0.created < $1.created }
        return ReadingExportSnapshot(title:scope == .book ? (store.commandWorkspace?.title ?? "阅读记录")+" · 阅读笔记" : "摘录与笔记",records:records)
    }
    private var empty:Bool { snapshot.records.isEmpty && snapshot.essay == nil }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("导出范围",selection:$scope) { ForEach(Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            Picker("导出格式",selection:$format) { ForEach(ReadingRecordExport.Format.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Text("原文、自己的笔记、图片与出处分别排版；返回原文以可点击的短文字显示。Markdown 图片放在同名配套目录中。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("刷新 Word 预览") { controller.preview(snapshot,assets:journal.folder.appendingPathComponent("Assets")) }.disabled(empty || controller.busy)
                Button("导出文件…",action:export).disabled(empty || controller.busy || (format == .word && controller.previewDigest != snapshot.digest))
                if controller.busy { ProgressView().controlSize(.small); Button("取消") { controller.cancel() } }
            }
            if let file = controller.previewURL { AcademicFilePreview(url:file).frame(minHeight:260,maxHeight:.infinity) }
            else { Text(format == .word ? "先生成实际 Word 文件预览，核对内容和出处后导出。" : "可直接导出，也可先查看 Word 排版预览。").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
            if controller.previewURL != nil && controller.previewDigest != snapshot.digest { Text("记录已更改，请刷新预览后导出 Word。").foregroundStyle(.orange) }
            Text(controller.message).font(.caption).textSelection(.enabled)
        }.onAppear { scope = store.readingExportEssay ? .essay : ((store.readingRecordID != nil || !store.readingRecordSelection.isEmpty) ? .selected : .book) }
        .onDisappear { controller.cancel() }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:format.ext) ?? .data]
        panel.nameFieldStringValue = String(snapshot.title.prefix(80)).replacingOccurrences(of:"/",with:"-")+"."+format.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let value = snapshot, kind = format, assets = journal.folder.appendingPathComponent("Assets"), model = journal, presenter = controller
        do {
            let baseline = try FileBaseline.capture(url)
            Task { do { try await model.flush(); presenter.export(value,format:kind,assets:assets,to:url,expected:baseline) } catch { presenter.message = error.localizedDescription } }
        } catch { controller.message = error.localizedDescription }
    }
}
