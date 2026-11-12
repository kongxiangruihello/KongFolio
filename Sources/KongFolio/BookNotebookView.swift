import SwiftUI
import PDFKit
import AppKit

struct BookNotebookView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var library: BookLibrary
    let book: LibraryBook
    var opensExport = false
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: BookNotebook.Snapshot?
    @State private var reflection = ""
    @State private var savedReflection = ""
    @State private var query = ""
    @State private var message = ""
    @State private var working = false
    @State private var initialized = false
    @State private var mode = 0
    @State private var recordSection = ReadingDeskSection.search
    @State private var bookExportAll = true
    @State private var annotationPage = 0
    @State private var annotationSize = 10
    private var source:ReadingCitation { ReadingCitation(source:SourceRef(path:ReadingProgress.canonicalPath(book.path),fileName:URL(fileURLWithPath:book.path).lastPathComponent,page:0),title:book.title) }
    private var notes:[AnnotationNote] { sections.flatMap(\.notes) }
    private var pagination:ReadingPagination { ReadingPagination(total:notes.count,page:annotationPage,size:annotationSize) }
    private var sections: [NotesSection] {
        (snapshot?.sections ?? []).compactMap { section in
            var section = section
            if !query.isEmpty { section.notes = section.notes.filter { ($0.quote + $0.note + $0.kind).localizedCaseInsensitiveContains(query) } }
            return section.notes.isEmpty ? nil : section
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:3) { Text(book.title).font(.system(size:20,weight:.semibold)).lineLimit(1).help(book.title);Text("这本书的阅读记录").font(.system(size:13)).foregroundStyle(.secondary) }
                Spacer()
                if mode == 0 && recordSection != .exports { Button("导出本书记录…") { bookExportAll = true;recordSection = .exports } }
                Button("关闭") { NSApp.keyWindow?.makeFirstResponder(nil);if saveReflection() { dismiss() } }.keyboardShortcut(.cancelAction)
            }
            Picker("阅读记录内容",selection:$mode) { Text("阅读记录").tag(0);Text("整本书心得").tag(1);Text("PDF 批注").tag(2) }.pickerStyle(.segmented)
            if mode == 0 {
                if recordSection == .exports {
                    Button("返回这本书的记录") { recordSection = .search }
                    ReadingExportPane(store:store,journal:store.journal,bookSource:source,bookExportAll:bookExportAll)
                } else {
                    let section = Binding(get:{recordSection},set:{ value in
                        if value == .exports { bookExportAll = false }
                        recordSection = value
                    })
                    ReadingLibraryView(store:store,journal:store.journal,section:section,bookSource:source)
                }
                ReadingSaveRecoveryFooter(journal:store.journal)
            } else if mode == 1 {
                Text("整本书的想法和阅读心得").font(.headline)
                LibraryWritingEditor(text:$reflection,label:"书架心得正文",identity:"shelf-reflection:"+book.id.uuidString)
                    .onChange(of:reflection) { _,_ in scheduleReflection() }
                Text("心得自动保存在个人书架，关闭时再次核对保存。").font(.system(size:13)).foregroundStyle(.secondary)
            } else {
                HStack { TextField("搜索 PDF 批注、高亮与图片摘录",text:$query).textFieldStyle(.roundedBorder);Menu("导出与编辑") { Button("导出笔记…") { export() };Button("生成可编辑笔记") { create() } }.disabled(snapshot == nil || working) }
                if working { ProgressView("正在汇总 PDF 批注…") }
                List(Array(notes.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { note in
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Text(WordExport.headText(note)).font(.system(size:13)).foregroundStyle(.secondary);Spacer();Button("返回原文") { reveal(note) } }
                        if !note.quote.isEmpty { Text(note.quote).font(.system(size:17)).textSelection(.enabled) }
                        if !note.note.isEmpty { Text("批注："+note.note).font(.system(size:17)).textSelection(.enabled) }
                        if note.quote.isEmpty && note.note.isEmpty { Text("图形或手写标注，请返回原文查看").foregroundStyle(.secondary) }
                    }.padding(.vertical,8)
                }
                ReadingPageControls(pagination:pagination,page:$annotationPage,size:$annotationSize)
                if !working && notes.isEmpty { Text("没有匹配的 PDF 批注，可在原书中高亮、手写或添加批注。").foregroundStyle(.secondary) }
            }
            if !message.isEmpty { Text(message).font(.system(size:13)).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(20).adaptiveSheet(width:1100,height:760,minimumWidth:360)
        .interactiveDismissDisabled(reflection != savedReflection)
        .onAppear { if !initialized { initialized = true;if opensExport { recordSection = .exports };reflection = library.books.first{$0.id == book.id}?.reflection ?? book.reflection;savedReflection = reflection } }
        .onReceive(NotificationCenter.default.publisher(for:.shelfReadingSourceOpened)) { note in
            guard note.object as? WorkspaceStore === store else { return }
            if saveReflection() { dismiss();store.showReadingHistory = false }
        }
        .onChange(of:library.error) { _,error in if let error { message = error } }
        .task(id:mode) { if mode == 2 && snapshot == nil { await load() } }
        .onChange(of:query) { _,_ in annotationPage = 0 }.onChange(of:annotationSize) { _,_ in annotationPage = 0 }
        .onDisappear { _ = saveReflection() }
    }
    private func load() async {
        working = true
        defer { working = false }
        do {
            let workspace = store.tabs.compactMap(\.workspace).first { $0.matches(path: book.path) && $0.count > 0 }
            guard workspace?.busy != true else { throw FolioError(message: "书籍正在处理，请稍后重新打开笔记") }
            let current = try workspace?.pdfData()
            snapshot = try await BookNotebook.load(book: book, currentPDF: current, cards: store.board.cards, outline: workspace?.outlineEntries)
            try Task.checkCancellation()
        } catch is CancellationError {} catch { message = error.localizedDescription }
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
