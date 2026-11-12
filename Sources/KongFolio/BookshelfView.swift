import SwiftUI
import AppKit
import PDFKit

struct BookLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var library: BookLibrary
    @StateObject private var addition = ManualShelfAddition()
    @AppStorage("KongFolio.shelf.sort") private var sort = ShelfSort.recent
    @AppStorage("KongFolio.shelf.grid") private var grid = false
    @AppStorage("KongFolio.shelf.pageSize") private var pageSize = 20
    @AppStorage("KongFolio.shelf.page") private var page = 0
    @AppStorage("KongFolio.shelf.scope") private var scope = "all"
    @State private var query = ""
    @State private var matchedQuery = ""
    @State private var selected = Set<UUID>()
    @State private var focused: UUID?
    @State private var progress: [String:ReadingProgress] = [:]
    @State private var fileStatus: [String:ShelfFileStatus] = [:]
    @State private var message = ""
    @State private var topicName = ""
    @State private var topicBooks = Set<UUID>()
    @State private var newTopic = false
    @State private var renamedTopic: String?
    @State private var pending = false
    @State private var editing: LibraryBook?
    @State private var notebook: NotebookRequest?
    @State private var relinkReview: ShelfRelinkReview?
    @State private var relinking = false
    @State private var opening = false
    @State private var fixedBook: LibraryBook?
    @State private var fixedPage = ""
    @State private var showFixedPage = false
    @State private var refresh = UUID()

    private struct NotebookRequest: Identifiable {
        let book: LibraryBook
        let export: Bool
        var id: UUID { book.id }
    }
    private let builtIn = [("all","全部书籍","books.vertical"),("reading","在读","book"),
                           ("unread","待读","bookmark"),("finished","已读","checkmark.circle"),
                           ("favorite","收藏","star")]
    private var size: Int { pageSize == 50 ? 50 : 20 }
    private var topic: String? { scope.hasPrefix("topic:") ? String(scope.dropFirst(6)) : nil }
    private var heading: String { topic ?? builtIn.first(where:{$0.0 == scope})?.1 ?? "全部书籍" }

    private var filtered: [LibraryBook] {
        let query = matchedQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        let values = library.books.filter { book in
            let status = book.shelfStatus(progress[book.path])
            let included: Bool
            if let topic { included = book.shelfTopics.contains { AnnotationFilter.folded($0) == AnnotationFilter.folded(topic) } }
            else {
                switch scope {
                case "reading": included = status == .reading
                case "unread": included = status == .unread
                case "finished": included = status == .finished
                case "favorite": included = book.favorite
                default: included = true
                }
            }
            return included && (query.isEmpty || book.matchingShelfField(query) != nil)
        }
        return ShelfBrowse.ordered(values,sort:sort,progress:progress)
    }

    var body: some View {
        let books = filtered
        let pagination = ReadingPagination(total:books.count,page:page,size:size)
        let visible = Array(books.dropFirst(pagination.range.lowerBound).prefix(size))
        let recent = scope == "all" && matchedQuery.isEmpty ? ShelfBrowse.recent(library.books,progress:progress) : []
        let checkPaths = Array(Set((visible + recent).map(\.path))).sorted()
        let allPaths = library.books.map(\.path)
        return GeometryReader { geometry in
            HStack(spacing:0) {
                if geometry.size.width >= 720 { sidebar;Divider() }
                VStack(alignment:.leading,spacing:12) {
                    toolbar(books)
                    if !recent.isEmpty { continueReading(recent) }
                    if geometry.size.width < 720 { scopeMenu }
                    if let detail = focused.flatMap({ id in visible.first { $0.id == id } }) { details(detail) }
                    collection(visible)
                    paginationBar(pagination)
                    feedback
                }
                .padding(16)
            }
        }
        .onAppear { progress = library.cachedShelfProgress }
        .task(id:query) {
            do { try await Task.sleep(for:.milliseconds(150)) } catch { return }
            if matchedQuery != query { page = 0;matchedQuery = query }
        }
        .task(id:allPaths+[refresh.uuidString]) { await updateProgress() }
        .task(id:checkPaths+[refresh.uuidString]) { await updateFileStatus(checkPaths) }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in refresh = UUID() }
        .onReceive(NotificationCenter.default.publisher(for:.shelfReadingProgressChanged)) { note in
            guard (note.object as? Workspace)?.store === store else { return }
            if let path = note.userInfo?["path"] as? String, let value = note.userInfo?["progress"] as? ReadingProgress {
                if allPaths.contains(path), progress[path] != value {
                    progress[path] = value
                    library.cachedShelfProgress[path] = value
                }
            }
        }
        .onChange(of:scope) { _,_ in page = 0;focused = nil }
        .onChange(of:sort) { _,_ in page = 0 }
        .onChange(of:size) { _,_ in page = 0 }
        .onChange(of:pagination.last) { _,last in if page > last { page = last } }
        .sheet(item:$editing) { ShelfBookEditor(library:library,book:$0) }
        .sheet(item:$notebook) { BookNotebookView(store:store,library:library,book:$0.book,opensExport:$0.export) }
        .sheet(isPresented:$pending) { PendingLibraryBooksView(library:library) }
        .alert(renamedTopic == nil ? "新建专题" : "重命名专题",isPresented:$newTopic) {
            TextField("专题名称",text:$topicName)
            Button("取消",role:.cancel) {}
            Button(renamedTopic == nil ? "创建" : "保存") {
                perform {
                    if let renamedTopic, let name = try library.updateShelfTopic(renamedTopic,replacement:topicName) { scope = "topic:"+name }
                    else { scope = "topic:"+(try library.addShelfTopic(topicName,adding:topicBooks)) }
                }
            }
        }
        .alert("保存固定页快捷方式",isPresented:$showFixedPage) {
            TextField("PDF 页码",text:$fixedPage)
            Button("取消",role:.cancel) {}
            Button("保存…") { if let book = fixedBook { saveFixed(book) } }
        } message: { Text("输入从 1 开始的 PDF 页码。") }
        .alert("核对替换文件",isPresented:Binding(get:{relinkReview != nil},set:{if !$0 { relinkReview = nil }}),presenting:relinkReview) { review in
            Button("取消",role:.cancel) { relinkReview = nil }
            Button("确认关联") { finishRelink(review) }
        } message: { review in Text(review.url.lastPathComponent+"\n"+review.message) }
        .dropDestination(for:URL.self) { urls,_ in
            let supported = urls.filter { $0.isFileURL && BookLibrary.supports($0) }
            guard !supported.isEmpty, !addition.busy else { return false }
            add(supported)
            return true
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:3) {
                Text("个人书架").font(.headline).padding(.bottom,10)
                ForEach(builtIn.indices,id:\.self) { index in
                    let item = builtIn[index]
                    scopeButton(item.0,item.1,item.2)
                }
                HStack {
                    Text("专题").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { promptTopic() } label: { Image(systemName:"plus") }
                        .buttonStyle(.borderless).help("新建专题").accessibilityLabel("新建专题")
                }.padding(.top,14).padding(.bottom,4)
                ForEach(library.shelfTopics,id:\.self) { topic in
                    scopeButton("topic:"+topic,topic,"folder").contextMenu {
                        Button("重命名专题…") { renamedTopic = topic;topicName = topic;newTopic = true }
                        Button("删除专题",role:.destructive) {
                            perform {
                                _ = try library.updateShelfTopic(topic,replacement:nil)
                                if self.topic == topic { scope = "all" }
                            }
                        }
                    }
                }
            }.padding(14)
        }.frame(width:160)
    }

    private func scopeButton(_ key:String,_ title:String,_ icon:String) -> some View {
        Button { scope = key } label: {
            Label(title,systemImage:icon).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                .padding(.horizontal,8).padding(.vertical,6)
                .background(scope == key ? Color.accentColor.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).help(title)
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(builtIn.indices,id:\.self) { index in
                let item = builtIn[index]
                Button(item.1) { scope = item.0 }
            }
            Divider()
            ForEach(library.shelfTopics,id:\.self) { topic in Button(topic) { scope = "topic:"+topic } }
            Button("新建专题…") { promptTopic() }
        } label: { Label(heading,systemImage:"line.3.horizontal.decrease") }
    }

    private func toolbar(_ books:[LibraryBook]) -> some View {
        VStack(alignment:.leading,spacing:8) {
            PanelRow {
                TextField("搜索书名、作者、刊名、年代或标签",text:$query).textFieldStyle(.roundedBorder)
                Menu {
                    Button("添加书籍…") { ShelfChooser.open(title:"添加到个人书架",multiple:true,action:{ add($0) }) }
                    Button("添加当前 PDF") {
                        guard let url = store.currentPDFForShelf else { return }
                        store.commandWorkspace?.saveReadingRecord()
                        add([url],bibliography:store.commandWorkspace?.bibliography)
                    }.disabled(store.currentPDFForShelf == nil)
                    Button("恢复旧版或已移出的书籍…") { pending = true }
                        .disabled((library.catalog.pendingBooks ?? []).isEmpty)
                } label: { Label("添加",systemImage:"plus") }.fixedSize().disabled(addition.busy)
                Picker("视图",selection:$grid) {
                    Image(systemName:"list.bullet").accessibilityLabel("列表").tag(false)
                    Image(systemName:"square.grid.2x2").accessibilityLabel("封面").tag(true)
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            PanelRow {
                Picker("排序",selection:$sort) {
                    ForEach(ShelfSort.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Spacer(minLength:0)
                if !selected.isEmpty {
                    Menu("已选 \(selected.count) 本") {
                        bulkActions(selected)
                        Divider()
                        Button("清空选择") { selected.removeAll() }
                    }.fixedSize()
                }
                Button("搜索 PDF 正文…") {
                    search(selected.isEmpty ? books : library.books.filter{selected.contains($0.id)})
                }.disabled(books.isEmpty && selected.isEmpty || store.folderSearch.running)
            }
        }
    }

    private func continueReading(_ books:[LibraryBook]) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text("继续阅读").font(.headline)
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    ForEach(books) { book in
                        Button { open(book) } label: {
                            HStack(spacing:8) {
                                LibraryCover(path:book.path).frame(width:34,height:44)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(progressLine(book)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(8).frame(width:172,alignment:.leading)
                                .background(.quaternary.opacity(0.55),in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).help(book.title)
                         .contextMenu { bookActions(book) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func collection(_ books:[LibraryBook]) -> some View {
        if books.isEmpty {
            VStack(spacing:8) {
                Image(systemName:"books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                Text(library.books.isEmpty ? "书架为空" : "没有匹配的书籍").font(.headline)
                if library.books.isEmpty { Text("通过「添加」或从访达拖入文献。").foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else if grid {
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:125),spacing:12)],spacing:12) {
                    ForEach(books) { book in
                        VStack(alignment:.leading,spacing:5) {
                            LibraryCover(path:book.path).frame(height:128).frame(maxWidth:.infinity)
                                .overlay(alignment:.topTrailing) { check(book).padding(6) }
                            bookLabel(book,lines:2)
                        }.padding(8)
                         .frame(maxWidth:.infinity,alignment:.leading)
                         .background(focused == book.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                         .modifier(ShelfRowGestures(single:{focused = book.id},double:{open(book)}))
                         .contextMenu { bookActions(book) }
                    }
                }.padding(.vertical,3)
            }
        } else {
            List(books) { book in
                HStack(spacing:10) {
                    check(book)
                    LibraryCover(path:book.path).frame(width:36,height:48)
                    bookLabel(book,lines:1)
                    Spacer(minLength:6)
                    if book.favorite { Image(systemName:"star.fill").foregroundStyle(.orange).accessibilityLabel("已收藏") }
                    Button { open(book) } label: { Image(systemName:"arrow.right.circle") }
                        .buttonStyle(.borderless).help("继续阅读").accessibilityLabel("继续阅读")
                }.padding(.vertical,4).frame(maxWidth:.infinity,alignment:.leading)
                 .modifier(ShelfRowGestures(single:{focused = book.id},double:{open(book)}))
                 .listRowBackground(focused == book.id ? Color.accentColor.opacity(0.10) : Color.clear)
                 .contextMenu { bookActions(book) }
            }.listStyle(.inset)
        }
    }

    private func check(_ book:LibraryBook) -> some View {
        Toggle("选择",isOn:Binding(get:{selected.contains(book.id)},set:{ checked in
            if checked { selected.insert(book.id) } else { selected.remove(book.id) }
        })).labelsHidden().help("勾选 "+book.title)
    }

    private func bookLabel(_ book:LibraryBook,lines:Int) -> some View {
        let metadata = [book.shelfAuthor,book.shelfPeriodical,book.shelfYear].compactMap{$0}.filter{!$0.isEmpty}
        return VStack(alignment:.leading,spacing:4) {
            Text(book.title).font(.callout.weight(.semibold)).lineLimit(lines).help(book.title)
            if !metadata.isEmpty { Text(metadata.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack(spacing:5) {
                Text(progressLine(book)).foregroundStyle(.secondary).lineLimit(1)
                if let field = book.matchingShelfField(matchedQuery) { Text("匹配"+field).foregroundStyle(Color.accentColor).lineLimit(1) }
            }.font(.caption)
        }
    }

    private func details(_ book:LibraryBook) -> some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(book.title).font(.headline).lineLimit(1).help(book.title)
                Spacer()
                Button { focused = nil } label: { Image(systemName:"xmark") }
                    .buttonStyle(.borderless).help("收起书籍详情")
            }
            PanelRow {
                Button("续读") { open(book) }.buttonStyle(.borderedProminent)
                Button("本书记录") { showNotebook(book) }
                Button("导出记录…") { showNotebook(book,export:true) }
                if fileStatus[book.path] == .missing { Button("重新定位…") { relink(book) } }
                Spacer(minLength:0)
            }
            Text(book.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle).help(book.path).textSelection(.enabled)
        }.padding(10).background(.quaternary.opacity(0.42),in:RoundedRectangle(cornerRadius:8))
    }

    private func paginationBar(_ pagination:ReadingPagination) -> some View {
        PanelRow {
            Text("\(pagination.total) 本").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { page = max(0,pagination.index-1) } label: { Image(systemName:"chevron.left") }.disabled(pagination.index == 0).help("上一页")
            Text("\(pagination.index+1) / \(pagination.last+1)").font(.caption.monospacedDigit())
            Button { page = pagination.index+1 } label: { Image(systemName:"chevron.right") }.disabled(pagination.index >= pagination.last).help("下一页")
            Picker("每页",selection:$pageSize) { Text("20 本").tag(20);Text("50 本").tag(50) }.fixedSize()
        }
    }

    @ViewBuilder private var feedback: some View {
        if addition.busy { HStack { ProgressView().controlSize(.small);Text("正在添加书籍…");Button("停止") { addition.cancel() } }.font(.caption) }
        if relinking { HStack { ProgressView().controlSize(.small);Text("正在核对文件…") }.font(.caption) }
        let status = library.error ?? (message.isEmpty ? addition.message : message)
        if !status.isEmpty || library.shelfUndoName != nil {
            HStack {
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                Spacer()
                if let name = library.shelfUndoName { Button("撤销"+name) { perform { try library.undoShelfEdit();message = "已撤销"+name } }.font(.caption) }
            }
        }
    }

    @ViewBuilder private func bookActions(_ book:LibraryBook) -> some View {
        Button("继续阅读") { open(book) }
        Button("本书记录") { showNotebook(book) }
        Button("导出本书记录…") { showNotebook(book,export:true) }
        Divider()
        Button("编辑书目信息…") { editing = book }
        Button(book.favorite ? "取消收藏" : "收藏") { change([book.id],"更改收藏") { $0.favorite = !book.favorite } }
        bulkActions(selected.contains(book.id) ? selected : [book.id])
        Divider()
        Button("在访达中显示") { revealInFinder(book) }
        Button("重新定位…") { relink(book) }.disabled(relinking)
        if !TextImport.handles(URL(fileURLWithPath:book.path)) {
            Menu("创建 Dock 快捷方式") {
                Button("继续读这本书…") { saveShortcut(book,page:nil) }
                Button("打开指定页…") {
                    fixedBook = book;fixedPage = String((progress[book.path]?.last ?? 0)+1);showFixedPage = true
                }
            }
        }
    }

    @ViewBuilder private func bulkActions(_ ids:Set<UUID>) -> some View {
        Menu("阅读状态") {
            ForEach(ShelfReadingStatus.allCases) { status in
                Button("标为"+status.rawValue) { change(ids,"更改阅读状态") { $0.readingStatus = status } }
            }
            Button("按进度自动判断") { change(ids,"更改阅读状态") { $0.readingStatus = nil } }
        }
        Menu("加入专题") {
            ForEach(library.shelfTopics,id:\.self) { topic in
                Button(topic) { change(ids,"加入专题") { $0.topics = ShelfBrowse.topics($0.shelfTopics+[topic]) } }
            }
            Button("新建专题…") { promptTopic(adding:ids) }
        }
        if let topic {
            Button("移出当前专题") {
                change(ids,"移出专题") { book in
                    let key = AnnotationFilter.folded(topic)
                    book.topics = book.shelfTopics.filter { AnnotationFilter.folded($0) != key }
                    if AnnotationFilter.folded(book.category) == key { book.category = "" }
                }
            }
        }
        Button(ids.count == 1 ? "移出书架" : "移出所选书籍",role:.destructive) {
            perform { try library.removeBooks(ids);selected.subtract(ids);message = "已移出 \(ids.count) 本书籍" }
        }
    }

    private func updateProgress() async {
        do {
            let snapshot = try await library.refreshHistory(defaults:store.readingDefaults)
            try Task.checkCancellation()
            progress = snapshot
            library.cachedShelfProgress = snapshot
        }
        catch where FolioCancellation.matches(error) {}
        catch { message = error.localizedDescription }
    }
    private func updateFileStatus(_ paths:[String]) async {
        let work = Task.detached(priority:.utility) { () -> [String:ShelfFileStatus] in
            var result: [String:ShelfFileStatus] = [:]
            for path in paths {
                if Task.isCancelled { break }
                result[path] = ShelfFileStatus.read(URL(fileURLWithPath:path))
            }
            return result
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        fileStatus = result
    }
    private func progressLine(_ book:LibraryBook) -> String {
        if let status = fileStatus[book.path]?.label { return status }
        guard let p = progress[book.path], let date = p.date, p.pages > 0 else { return book.shelfStatus(progress[book.path]).rawValue }
        return date.formatted(.relative(presentation:.named))+" · 第 \(p.last+1) / \(p.pages) 页"
    }
    private func promptTopic(adding ids:Set<UUID> = []) { renamedTopic = nil;topicName = "";topicBooks = ids;newTopic = true }
    private func perform(_ work:() throws -> Void) { do { try work() } catch { message = error.localizedDescription } }
    private func change(_ ids:Set<UUID>,_ name:String,_ edit:(inout LibraryBook)->Void) {
        perform { try library.editShelfBooks(ids,name:name,edit:edit);message = "已"+name }
    }
    private func add(_ urls:[URL],bibliography:Bibliography? = nil) {
        message = "";query = "";matchedQuery = "";scope = "all";page = 0
        addition.add(urls,to:library,bibliography:bibliography)
    }
    private func open(_ book:LibraryBook) {
        guard !opening else { return }
        let shortcut = library.resolve(ReadingShortcut(path:book.path,title:book.title,position:ViewPosition(selection:0),bookmark:book.bookmark))
        opening = true
        Task {
            defer { opening = false }
            do {
                let url = try await Task.detached(priority:.userInitiated) { try shortcut.resolvedURL() }.value
                try store.openLibraryBook(book,resolvedFile:url)
                store.showReadingHistory = false
            } catch {
                if fileStatus[book.path] == .missing { relink(book) }
                else { message = error.localizedDescription }
            }
        }
    }
    private func showNotebook(_ book:LibraryBook,export:Bool = false) { notebook = NotebookRequest(book:book,export:export) }
    private func search(_ books:[LibraryBook]) {
        let pdfs = books.filter { $0.isPDF || URL(fileURLWithPath:$0.path).pathExtension.lowercased() == "kongfolio" }
        guard !pdfs.isEmpty else { message = "当前范围没有 PDF。";return }
        let shortcuts = pdfs.map {
            library.resolve(ReadingShortcut(path:$0.path,title:$0.title,position:ViewPosition(selection:0),bookmark:$0.bookmark))
        }
        Task {
            let urls = await Task.detached(priority:.utility) {
                shortcuts.map { (try? $0.resolvedURL()) ?? URL(fileURLWithPath:$0.path) }
            }.value
            store.folderSearch.libraryFiles = urls
            store.folderSearch.scope = .library
            store.showReadingHistory = false
            DispatchQueue.main.async { store.showFolderSearch = true }
        }
    }
    private func revealInFinder(_ book:LibraryBook) {
        perform {
            let shortcut = library.resolve(ReadingShortcut(path:book.path,title:book.title,position:ViewPosition(selection:0),bookmark:book.bookmark))
            NSWorkspace.shared.activateFileViewerSelecting([try shortcut.resolvedURL()])
        }
    }
    private func relink(_ book:LibraryBook) {
        ShelfChooser.open(title:"重新定位 "+book.title,multiple:false) { urls in
            guard let url = urls.first else { return }
            relinking = true
            Task {
                defer { relinking = false }
                do {
                    let review = try await Task.detached(priority:.utility) { try ShelfRelinkReview.inspect(book,url:url) }.value
                    if review.verified { finishRelink(review) } else { relinkReview = review }
                } catch { message = error.localizedDescription }
            }
        }
    }
    private func finishRelink(_ review:ShelfRelinkReview) {
        relinkReview = nil
        perform {
            guard library.books.contains(where:{$0.id == review.book.id && $0.path == review.book.path}) else {
                throw FolioError(message:"书架记录已变化，请重新定位")
            }
            try library.relink(path:review.book.path,to:review.url,defaults:store.readingDefaults,validated:true,verifiedDigest:review.digest)
            refresh = UUID();message = "已重新定位"
        }
    }
    private func saveFixed(_ book:LibraryBook) {
        guard let page = Int(fixedPage.trimmingCharacters(in:.whitespaces)), (1...1_000_000).contains(page) else {
            message = "请输入有效的 PDF 页码";return
        }
        let shortcut = library.resolve(ReadingShortcut(path:book.path,title:book.title,position:ViewPosition(selection:0),bookmark:book.bookmark))
        let known = progress[book.path]?.pages ?? 0
        Task {
            do {
                let pages = try await Task.detached(priority:.utility) {
                    let url = try shortcut.resolvedURL()
                    if ShelfFileStatus.read(url) == .available && book.isPDF {
                        guard let document = PDFDocument(url:url), !document.isLocked else { throw FolioError(message:"请先打开并解锁 PDF") }
                        return document.pageCount
                    }
                    return known
                }.value
                guard pages > 0 else { throw FolioError(message:"请先打开这本书以确认总页数") }
                guard page <= pages else { throw FolioError(message:"这本书共 \(pages) 页，请重新输入") }
                saveShortcut(book,page:page-1)
            } catch { message = error.localizedDescription }
        }
    }
    private func saveShortcut(_ book:LibraryBook,page:Int?) {
        let previous = progress[book.path]
        let position = page.map { ViewPosition(selection:$0) } ?? previous?.resumePosition(pageCount:previous?.pages ?? 0) ?? ViewPosition(selection:0)
        let shortcut = ReadingShortcut(path:book.path,title:book.title,mode:page == nil ? .resume : .fixed,
                                       position:position,layout:previous?.layout,bookmark:book.bookmark)
        ShelfChooser.saveShortcut(shortcut,library:library) { message = $0 }
    }
}

private struct ShelfRowGestures: ViewModifier {
    let single: ()->Void
    let double: ()->Void
    func body(content:Content) -> some View {
        content.contentShape(Rectangle())
            .onTapGesture(count:2,perform:double)
            .onTapGesture(perform:single)
    }
}
