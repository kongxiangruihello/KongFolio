import SwiftUI

struct TextVersionHistoryView: View {
    @ObservedObject var note: MarkdownNote
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [HistoryEntry] = []
    @State private var selected: UUID?
    @State private var previous: String?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.title + " · 保存历史").font(.headline)
            Picker("历史版本", selection: $selected) {
                Text("选择版本").tag(nil as UUID?)
                ForEach(entries) { entry in Text(entry.created.formatted(date: .abbreviated, time: .standard) + " · " + entry.label).tag(entry.id as UUID?) }
            }
            HSplitView {
                VStack(alignment: .leading) { Text("历史版本").font(.caption); ScrollView { Text(previous ?? "尚无版本，覆盖保存前会自动保留原件。").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } }.frame(minWidth: 150)
                VStack(alignment: .leading) { Text("当前内容（含未保存编辑）").font(.caption); ScrollView { Text(note.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } }.frame(minWidth: 150)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            Text("恢复会写回原文件；恢复前先保留当前工作，之后仍可找回。遇到外部修改会停止恢复。").font(.caption).foregroundStyle(.secondary)
            PanelRow {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("恢复选中版本") { if let entry = entries.first(where: { $0.id == selected }), note.restoreTextVersion(entry) { dismiss() } else { message = note.error ?? "无法恢复" } }.disabled(previous == nil)
            }
        }.padding(20).adaptiveSheet(width: 900, height: 620, minimumWidth: 360)
        .onAppear { do { if let source = note.fileURL { entries = try TextVersionHistory.list(source: source, storage: note.storage); selected = entries.first?.id; load() } } catch { message = error.localizedDescription } }
        .onChange(of: selected) { _, _ in load() }
    }
    private func load() {
        previous = nil
        do { if let entry = entries.first(where: { $0.id == selected }), let source = note.fileURL { previous = try TextVersionHistory.read(entry, source: source, storage: note.storage).text } }
        catch { message = error.localizedDescription }
    }
}
