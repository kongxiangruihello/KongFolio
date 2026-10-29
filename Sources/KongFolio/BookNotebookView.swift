import SwiftUI
import PDFKit
import AppKit

struct BookNotebookView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var library: BookLibrary
    let book: LibraryBook
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: BookNotebook.Snapshot?
    @State private var reflection = ""
    @State private var savedReflection = ""
    @State private var query = ""
    @State private var message = ""
    @State private var working = true
    private var sections: [NotesSection] {
        (snapshot?.sections ?? []).compactMap { section in
            var section = section
            if !query.isEmpty { section.notes = section.notes.filter { ($0.quote + $0.note + $0.kind).localizedCaseInsensitiveContains(query) } }
            return section.notes.isEmpty ? nil : section
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelRow { Text(book.title + " · 阅读笔记").font(.headline); Spacer(); Button("关闭") { if saveReflection() { dismiss() } }.keyboardShortcut(.cancelAction); Button("导出笔记…") { export() }.disabled(snapshot == nil || working); Button("生成可编辑笔记") { create() }.disabled(snapshot == nil || working) }
            Text("我的心得（自动保存在书架中）").font(.caption)
            TextEditor(text: $reflection).frame(minHeight: 70, maxHeight: 120).border(.quaternary)
                .onChange(of: reflection) { _, _ in scheduleReflection() }
                .onChange(of: library.error) { _, error in if let error { message = error } }
            TextField("搜索高亮、批注、摘录", text: $query).textFieldStyle(.roundedBorder)
            if working { ProgressView("正在汇总书籍笔记…") }
            List {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section(section.title) {
                        ForEach(section.notes) { note in
                            VStack(alignment: .leading, spacing: 5) {
                                PanelRow {
                                    Text(WordExport.headText(note)).font(.caption).foregroundStyle(.secondary)
                                    Spacer(); Button("返回原文") { reveal(note) }
                                }
                                if !note.quote.isEmpty { Text(note.quote).textSelection(.enabled) }
                                if !note.note.isEmpty { Text("批注：" + note.note).textSelection(.enabled) }
                                if note.quote.isEmpty && note.note.isEmpty { Text("图形或手写标注，请返回原文查看").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
            if !working && sections.isEmpty { Text(query.isEmpty ? "尚无标注或摘录，可先记录心得，再到原书中高亮、手写或添加批注。" : "没有匹配的笔记。").font(.caption).foregroundStyle(.secondary) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }.padding(20).adaptiveSheet(width: 820, height: 680, minimumWidth: 360)
        .interactiveDismissDisabled(reflection != savedReflection)
        .task { await load() }
        .onDisappear { _ = saveReflection() }
    }
    private func load() async {
        reflection = library.books.first { $0.id == book.id }?.reflection ?? book.reflection; savedReflection = reflection
        do {
            let workspace = store.tabs.compactMap(\.workspace).first { $0.matches(path: book.path) && $0.count > 0 }
            guard workspace?.busy != true else { throw FolioError(message: "书籍正在处理，请稍后重新打开笔记") }
            let current = try workspace?.pdfData()
            snapshot = try await BookNotebook.load(book: book, currentPDF: current, cards: store.board.cards, outline: workspace?.outlineEntries)
            try Task.checkCancellation()
        } catch is CancellationError {} catch { message = error.localizedDescription }
        working = false
    }
    private func scheduleReflection() {
        do { try library.scheduleReflection(book.id, text: reflection) }
        catch { message = "心得未保存：" + error.localizedDescription }
    }
    @discardableResult private func saveReflection() -> Bool {
        guard reflection != savedReflection else { return true }
        do { var current = library.books.first { $0.id == book.id } ?? book; current.reflection = reflection; try library.update(current); savedReflection = reflection; return true }
        catch { message = "心得未保存：" + error.localizedDescription; return false }
    }
    private func content() -> String { var value = snapshot; value?.reflection = reflection; return value?.markdown ?? "" }
    private func create() {
        guard saveReflection() else { return }; let text = content(); dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { let note = store.newNote(); note.text = text; note.status = "已生成带返回原文链接的阅读笔记，可继续编辑或导出 PDF / Word" }
    }
    private func export() {
        guard saveReflection() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = book.title + "-阅读笔记.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let expected = try FileBaseline.capture(url); try DocumentTaskOutput.write(to: url, expected: expected) { try content().write(to: $0, atomically: true, encoding: .utf8) }; message = "已导出带返回原文链接的笔记" }
        catch { message = error.localizedDescription }
    }
    private func reveal(_ note: AnnotationNote) {
        guard saveReflection() else { return }
        do {
            let shortcut = ReadingShortcut(path: book.path, title: book.title, mode: .fixed, position: ViewPosition(selection: note.page), bookmark: book.bookmark)
            try store.openReadingShortcut(shortcut); dismiss(); store.showReadingHistory = false
        } catch { message = error.localizedDescription }
    }
}
