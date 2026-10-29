import SwiftUI
import PDFKit
import AppKit

struct BookLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var library: BookLibrary
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var category = "全部分类"
    @State private var selected = Set<UUID>()
    @State private var message = ""
    @State private var notebook: LibraryBook?
    @State private var refreshing = false
    @State private var refreshToken = UUID()
    @State private var progress: [String: ReadingProgress] = [:]
    private var categories: [String] { ["全部分类"] + Set(library.books.map(\.category).filter { !$0.isEmpty }).sorted() }
    private var visible: [LibraryBook] {
        library.books.filter { book in
            (!favoritesOnly || book.favorite) && (category == "全部分类" || book.category == category) && (query.isEmpty || (book.title + book.path + book.category).localizedCaseInsensitiveContains(query))
        }.sorted { (progress[$0.path]?.date ?? $0.added) > (progress[$1.path]?.date ?? $1.added) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelRow {
                TextField("搜索书名、分类或路径", text: $query).textFieldStyle(.roundedBorder)
                Toggle("只看收藏", isOn: $favoritesOnly)
                Picker("分类", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 220)
            }
            PanelRow {
                Button("添加书籍…") { add() }
                Button("刷新进度") { refreshToken = UUID() }.disabled(refreshing)
                Button(selected.isEmpty ? "搜索全部书架…" : "搜索所选 \(selected.count) 本…") { search() }.disabled(library.books.isEmpty || store.folderSearch.running)
                Text("⌘ 点选可同时选择多本").font(.caption).foregroundStyle(.secondary)
            }
            List(selection: $selected) {
                ForEach(visible) { book in row(book).tag(book.id) }
            }.overlay { if visible.isEmpty { Text("暂无书籍。添加文件，或打开一本书后刷新书架。").foregroundStyle(.secondary) } }
            if let error = library.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Text("书籍保留在原位置；书架只记录分类、心得与阅读进度。链接失效时可重新指定原文件。").font(.caption).foregroundStyle(.secondary)
            if refreshing { HStack { ProgressView().controlSize(.small); Text("后台整理阅读记录，可继续搜索和浏览…").font(.caption) } }
        }.task(id:refreshToken) { await refresh() }.sheet(item: $notebook) { BookNotebookView(store: store, library: library, book: $0) }
    }
    private func row(_ book: LibraryBook) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LibraryCover(path: book.path).frame(width: 48, height: 66)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                if let p = progress[book.path], p.date != nil {
                    Text("读到第 \(p.last + 1) 页 / 共 \(p.pages) 页").font(.caption)
                    ProgressView(value: min(1, max(0, p.fraction(pageCount: p.pages)))).frame(maxWidth: 200)
                }
                Text(book.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    TextField("分类", text: Binding(get: { library.books.first { $0.id == book.id }?.category ?? "" }, set: { value in perform { var b = library.books.first { $0.id == book.id } ?? book; b.category = value; try library.update(b) } })).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button { perform { var b = book; b.favorite.toggle(); try library.update(b) } } label: { Image(systemName: book.favorite ? "star.fill" : "star") }.help("收藏或取消收藏这本书")
                    Button("笔记") { notebook = book }.disabled(TextImport.handles(URL(fileURLWithPath: book.path)))
                }
            }
            Spacer(minLength: 0)
            VStack {
                Button("继续阅读") { perform { try store.openLibraryBook(book); store.showReadingHistory = false } }
                Button("重新定位…") { relink(book) }.help("文件移动后，重新选择文件并保留进度与心得")
            }
        }.padding(.vertical, 5)
    }
    private func refresh() async {
        refreshing = true; defer { refreshing = false }
        do { progress = try await library.refreshHistory(defaults:store.readingDefaults) }
        catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func add() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.message = "添加 PDF、KongFolio 项目、Markdown、HTML 或文本文件；原件保留在原位置。"
        guard panel.runModal() == .OK else { return }
        perform { try library.add(panel.urls); refreshToken = UUID() }
    }
    private func relink(_ book: LibraryBook) {
        let panel = NSOpenPanel(); panel.message = "重新选择“\(book.title)”的原文件，保留进度、分类和心得。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try library.relink(path: book.path, to: url, defaults: store.readingDefaults); refreshToken = UUID(); message = "已重新定位；阅读链接将使用新位置。" }
    }
    private func search() {
        let books = selected.isEmpty ? library.books : library.books.filter { selected.contains($0.id) }
        store.folderSearch.libraryFiles = books.map { book in (try? library.resolve(ReadingShortcut(path: book.path, title: book.title, position: ViewPosition(selection: 0), bookmark: book.bookmark)).resolvedURL()) ?? URL(fileURLWithPath: book.path) }
        store.folderSearch.scope = .library
        store.showReadingHistory = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.showFolderSearch = true }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
}

private struct LibraryCover: View {
    let path: String
    @State private var cover: NSImage?
    var body: some View {
        Group {
            if let cover { Image(nsImage: cover).resizable().scaledToFit() }
            else { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.blue).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 5)) }
        }.task(id: path) {
            do {
                let data = try await LibraryCoverLoader.shared.load(URL(fileURLWithPath:path))
                try Task.checkCancellation(); cover = data.flatMap(NSImage.init(data:))
            } catch { cover = nil }

        }
    }
}
