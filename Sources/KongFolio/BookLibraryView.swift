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
    @State private var editing: LibraryBook?
    @State private var pending = false
    @State private var page = 0
    @State private var refreshing = false
    @State private var refreshToken = UUID()
    @State private var progress: [String: ReadingProgress] = [:]
    private var categories: [String] { ["全部分类"] + Set(library.books.map(\.category).filter { !$0.isEmpty }).sorted() }
    private var visible: [LibraryBook] {
        library.books.filter { book in
            (!favoritesOnly || book.favorite) && (category == "全部分类" || book.category == category) && (query.isEmpty || (book.title + book.path + book.category).localizedCaseInsensitiveContains(query))
        }.sorted {
            let a = progress[$0.path]?.date ?? $0.added, b = progress[$1.path]?.date ?? $1.added
            return a == b ? $0.path < $1.path : a > b
        }
    }
    private var lastPage: Int { max(0,(visible.count-1)/20) }
    private var pageBooks: [LibraryBook] { Array(visible.dropFirst(min(page,lastPage)*20).prefix(20)) }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            PanelRow {
                TextField("搜索书名、分类或路径",text:$query).textFieldStyle(.roundedBorder)
                Toggle("只看收藏",isOn:$favoritesOnly)
                Picker("分类",selection:$category) { ForEach(categories,id:\.self) { Text($0).tag($0) } }.frame(maxWidth:220)
            }
            PanelRow {
                Button("添加书籍…",action:add)
                Button("刷新进度") { refreshToken = UUID() }.disabled(refreshing)
                Button("从旧版或已移出记录中添加…") { pending = true }.disabled((library.catalog.pendingBooks ?? []).isEmpty)
                Button("移出所选书籍") { perform { try library.removeBooks(selected); selected = [] } }.disabled(selected.isEmpty)
            }
            PanelRow {
                Button(selected.isEmpty ? "搜索全部书架…" : "搜索所选 \(selected.count) 本…",action:search).disabled(library.books.isEmpty || store.folderSearch.running)
                Text("勾选可选择多本，翻页后保留选择").font(.caption).foregroundStyle(.secondary)
            }
            List { ForEach(pageBooks) { book in row(book) } }
                .overlay { if visible.isEmpty { Text(library.books.isEmpty ? "书架为空，请手动添加书籍。阅读其他文件不会自动加入。" : "没有匹配的书籍").foregroundStyle(.secondary) } }
            PanelRow {
                Text("共 \(visible.count) 本 · 已选 \(selected.count) 本").font(.caption); Spacer()
                Button("上一页") { page = max(0,page-1) }.disabled(page == 0)
                Text("第 \(min(page,lastPage)+1) / \(lastPage+1) 页").font(.caption)
                Button("下一页") { page += 1 }.disabled(page >= lastPage)
            }
            if let error = library.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Text("书架由你手动维护；编辑书名、分类或心得不会改动原件。移出后，阅读记录和笔记继续保留。").font(.caption).foregroundStyle(.secondary)
            if refreshing { HStack { ProgressView().controlSize(.small); Text("正在后台读取进度…").font(.caption) } }
        }.task(id:refreshToken) { await refresh() }
        .onChange(of:query) { _,_ in page = 0 }.onChange(of:category) { _,_ in page = 0 }.onChange(of:favoritesOnly) { _,_ in page = 0 }
        .sheet(item:$notebook) { BookNotebookView(store:store,library:library,book:$0) }
        .sheet(item:$editing) { ShelfBookEditor(library:library,book:$0) }
        .sheet(isPresented:$pending) { PendingLibraryBooksView(library:library) }
    }
    private func row(_ book:LibraryBook) -> some View {
        HStack(alignment:.top,spacing:12) {
            Toggle("选择",isOn:Binding(get:{selected.contains(book.id)},set:{ if $0 { selected.insert(book.id) } else { selected.remove(book.id) } })).labelsHidden().help("选择“\(book.title)”")
            LibraryCover(path:book.path).frame(width:48,height:66)
            VStack(alignment:.leading,spacing:4) {
                Text(book.title).font(.headline).lineLimit(2).help(book.title)
                if let p = progress[book.path], p.date != nil { Text("读到第 \(p.last+1) 页 / 共 \(p.pages) 页").font(.caption) }
                Text(book.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(book.path)
                HStack {
                    if !book.category.isEmpty { Text(book.category).font(.caption) }
                    Button { perform { var b = book; b.favorite.toggle(); try library.update(b) } } label: { Image(systemName:book.favorite ? "star.fill" : "star") }.help("收藏或取消收藏")
                    Button("编辑") { editing = book }
                    Button("笔记") { if store.readingMode { perform { try store.openLibraryBook(book); store.showReadingHistory = false; store.openReadingDesk(.notes,window:true) } } else { notebook = book } }.disabled(TextImport.handles(URL(fileURLWithPath:book.path)))
                }
            }
            Spacer(minLength:0)
            VStack {
                Button("继续阅读") { perform { try store.openLibraryBook(book); store.showReadingHistory = false } }
                Button("重新定位…") { relink(book) }
            }
        }.padding(.vertical,5)
    }
    private func refresh() async {
        refreshing = true; defer { refreshing = false }
        do { progress = try await library.refreshHistory(defaults:store.readingDefaults) }
        catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func add() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.message = "手动添加书籍；原件保留在原位置。"
        guard panel.runModal() == .OK else { return }
        perform { try library.add(panel.urls); refreshToken = UUID() }
    }
    private func relink(_ book:LibraryBook) {
        let panel = NSOpenPanel(); panel.message = "重新选择“\(book.title)”的原文件，保留进度、分类和心得。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try library.relink(path:book.path,to:url,defaults:store.readingDefaults); refreshToken = UUID(); message = "已重新定位" }
    }
    private func search() {
        let books = selected.isEmpty ? library.books : library.books.filter { selected.contains($0.id) }
        store.folderSearch.libraryFiles = books.map { book in (try? library.resolve(ReadingShortcut(path:book.path,title:book.title,position:ViewPosition(selection:0),bookmark:book.bookmark)).resolvedURL()) ?? URL(fileURLWithPath:book.path) }
        store.folderSearch.scope = .library; store.showReadingHistory = false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { store.showFolderSearch = true }
    }
    private func perform(_ action:() throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
}

struct ShelfBookEditor: View {
    @ObservedObject var library:BookLibrary
    let book:LibraryBook
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = ""
    @State private var reflection = ""
    @State private var favorite = false
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("编辑书架记录").font(.headline)
            TextField("书名",text:$title); TextField("分类",text:$category); Toggle("收藏",isOn:$favorite)
            Text("整本书的心得").font(.caption); TextEditor(text:$reflection).frame(minHeight:150)
            Text(book.path).font(.caption).textSelection(.enabled)
            Text(message).foregroundStyle(.red)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(20).adaptiveSheet(width:560,height:380,minimumWidth:360)
        .onAppear { title = book.title; category = book.category; reflection = book.reflection; favorite = book.favorite }
    }
    private func save() {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { message = "请填写书名"; return }
        do { var b = book; b.title = title; b.category = category; b.reflection = reflection; b.favorite = favorite; try library.update(b); dismiss() } catch { message = error.localizedDescription }
    }
}

struct PendingLibraryBooksView: View {
    @ObservedObject var library:BookLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var query = ""
    @State private var page = 0
    @State private var message = ""
    private var matches:[LibraryBook] { (library.catalog.pendingBooks ?? []).filter { query.isEmpty || ($0.title+$0.category).localizedCaseInsensitiveContains(query) } }
    private var lastPage:Int { max(0,(matches.count-1)/25) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("旧版与已移出的书架记录").font(.headline)
            Text("这些记录仍保留分类、收藏和心得。只有你选择添加后，才会出现在书架中。").font(.caption)
            TextField("筛选待添加书名",text:$query)
            HStack { Button("全选筛选结果") { selected.formUnion(matches.map(\.id)) }; Button("清空勾选") { selected = [] }; Text("已选 \(selected.count) 本") }
            List(Array(matches.dropFirst(min(page,lastPage)*25).prefix(25))) { book in
                Toggle(isOn:Binding(get:{selected.contains(book.id)},set:{ if $0 { selected.insert(book.id) } else { selected.remove(book.id) } })) { Text(book.title).lineLimit(1).help(book.title+"\n"+book.path) }
            }
            HStack { Text("第 \(min(page,lastPage)+1) / \(lastPage+1) 页"); Button("上一页") { page = max(0,page-1) }.disabled(page == 0); Button("下一页") { page += 1 }.disabled(page >= lastPage) }
            Text(message).foregroundStyle(.red)
            HStack { Button("关闭") { dismiss() }; Spacer(); Button("添加所选书籍") { do { try library.acceptPending(selected); dismiss() } catch { message = error.localizedDescription } }.disabled(selected.isEmpty) }
        }.padding(20).adaptiveSheet(width:720,height:560,minimumWidth:360).onChange(of:query) { _,_ in page = 0 }
    }
}

private struct LibraryCover: View {
    let path:String
    @State private var cover:NSImage?
    var body:some View {
        Group {
            if let cover { Image(nsImage:cover).resizable().scaledToFit() }
            else { Image(systemName:"book.closed").font(.largeTitle).foregroundStyle(.blue).frame(maxWidth:.infinity,maxHeight:.infinity).background(.quaternary,in:RoundedRectangle(cornerRadius:5)) }
        }.task(id:path) { do { let data = try await LibraryCoverLoader.shared.load(URL(fileURLWithPath:path)); try Task.checkCancellation(); cover = data.flatMap(NSImage.init(data:)) } catch { cover = nil } }
    }
}
