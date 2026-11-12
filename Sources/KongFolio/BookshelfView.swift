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
    @AppStorage("KongFolio.shelf.query") private var query = ""
    @AppStorage("KongFolio.shelf.focused") private var focusedKey = ""
    @AppStorage("KongFolio.shelf.year") private var filterYear = ""
    @AppStorage("KongFolio.shelf.periodical") private var filterPeriodical = ""
    @AppStorage("KongFolio.shelf.status") private var filterStatus = ""
    @AppStorage("KongFolio.shelf.withExcerpts") private var filterExcerpts = false
    @ObservedObject private var journal:ReadingJournal
    @StateObject private var sourceNavigator = ReadingSourceNavigator()
    @State private var summaries: [String:ShelfRecordSummary] = [:]
    @State private var importRequest: ShelfImportRequest?
    @State private var showFiles = false
    @State private var showFilters = false
    @State private var saveFilter = false
    @State private var filterTitle = ""
    @State private var periodicalsExpanded = false
    @State private var matchedQuery = ""
    @State private var selected = Set<UUID>()
    private var focused: UUID? {
        get { UUID(uuidString:focusedKey) }
        nonmutating set { focusedKey = newValue?.uuidString ?? "" }
    }

    init(store:WorkspaceStore,library:BookLibrary) {
        self.store = store
        self.library = library
        _journal = ObservedObject(wrappedValue:store.journal)
    }
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
                           ("favorite","收藏","star"),("queue","待读队列","list.number")]
    private var size: Int { pageSize == 50 ? 50 : 20 }
    private var topic: String? { scope.hasPrefix("topic:") ? String(scope.dropFirst(6)) : nil }
    private var periodical: String? { scope.hasPrefix("periodical:") ? String(scope.dropFirst(11)) : nil }
    private var heading: String { topic ?? periodical ?? builtIn.first(where:{$0.0 == scope})?.1 ?? "全部书籍" }
    private var periodicals: [String] {
        var known = Set<String>()
        return library.books.map{$0.issueMetadata.periodical}.filter { !$0.isEmpty && known.insert(ShelfText.key($0)).inserted }
            .sorted{$0.localizedStandardCompare($1) == .orderedAscending}
    }
    private var filtering: Bool { !filterYear.isEmpty || !filterPeriodical.isEmpty || !filterStatus.isEmpty || filterExcerpts }

    private var filtered: [LibraryBook] {
        let query = matchedQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        let source = scope == "queue" ? library.readingQueue : library.books
        let titleKey = ShelfText.key(periodical ?? "")
        let filterKey = ShelfText.key(filterPeriodical)
        let values = source.filter { book in
            let status = book.shelfStatus(progress[book.path])
            let included: Bool
            if let topic { included = book.shelfTopics.contains { AnnotationFilter.folded($0) == AnnotationFilter.folded(topic) } }
            else if periodical != nil { included = ShelfText.key(book.issueMetadata.periodical) == titleKey }
            else {
                switch scope {
                case "reading": included = status == .reading
                case "unread": included = status == .unread
                case "finished": included = status == .finished
                case "favorite": included = book.favorite
                default: included = true
                }
            }
            guard included,
                  filterYear.isEmpty || book.issueMetadata.year.localizedCaseInsensitiveContains(filterYear),
                  filterKey.isEmpty || ShelfText.key(book.issueMetadata.periodical).contains(filterKey),
                  filterStatus.isEmpty || status.rawValue == filterStatus,
                  !filterExcerpts || summaries[ReadingBookIdentity.key(book.path)]?.hasExcerpts == true else { return false }
            return query.isEmpty || book.matchingShelfField(query) != nil
        }
        if scope == "queue" { return values }
        if periodical != nil { return ShelfText.issueOrder(values) }
        return ShelfBrowse.ordered(values,sort:sort,progress:progress)
    }

    var body: some View {
        let books = filtered
        let pagination = ReadingPagination(total:books.count,page:page,size:size)
        let visible = Array(books.dropFirst(pagination.range.lowerBound).prefix(size))
        let recent = scope == "all" && matchedQuery.isEmpty && !filtering ? ShelfBrowse.recent(library.books,progress:progress) : []
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
                    browserCollection(visible)
                    paginationBar(pagination)
                    feedback
                }
                .padding(16)
            }
        }
        .onAppear { progress = library.cachedShelfProgress;matchedQuery = query;periodicalsExpanded = periodical != nil }
        .task(id:journal.revisionID) { await updateSummaries() }
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
        .onChange(of:scope) { _,_ in page = 0;focused = nil;if periodical != nil { periodicalsExpanded = true } }
        .onChange(of:sort) { _,_ in page = 0 }
        .onChange(of:size) { _,_ in page = 0 }
        .onChange(of:filterYear) { _,_ in page = 0 }
        .onChange(of:filterPeriodical) { _,_ in page = 0 }
        .onChange(of:filterStatus) { _,_ in page = 0 }
        .onChange(of:filterExcerpts) { _,_ in page = 0 }
        .onReceive(NotificationCenter.default.publisher(for:.shelfReadingSourceOpened)) { note in
            if note.object as? WorkspaceStore === store { store.showReadingHistory = false }
        }
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
        .sheet(item:$relinkReview) { review in
            ShelfCompareFiles(original:review.book,candidate:review.url,knownPages:progress[review.book.path]?.pages,
                              detail:review.verified ? "已确认是同一份文件。" : review.message,
                              confirm:{ finishRelink(review) })
        }
        .sheet(item:$importRequest) { request in
            ShelfImportReview(request:request) { drafts in add(drafts.map(\.url),drafts:drafts) }
        }
        .sheet(isPresented:$showFiles) {
            ShelfFileIssues(books:library.books,progress:progress) { book in relink(book) }
        }
        .sheet(item:$sourceNavigator.review,onDismiss:{sourceNavigator.cancel()}) {
            ReadingSourceReviewSheet(request:$0,navigator:sourceNavigator,store:store).id($0.id)
        }
        .alert("保存常用筛选",isPresented:$saveFilter) {
            TextField("筛选名称",text:$filterTitle)
            Button("取消",role:.cancel) {}
            Button("保存") { storeFilter() }
        }
        .dropDestination(for:URL.self) { urls,_ in
            let supported = urls.filter { $0.isFileURL && BookLibrary.supports($0) }
            guard !supported.isEmpty, !addition.busy else { return false }
            previewImport(supported)
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
                if !periodicals.isEmpty {
                    DisclosureGroup("按刊物",isExpanded:$periodicalsExpanded) {
                        ForEach(periodicals,id:\.self) { name in scopeButton("periodical:"+name,name,"newspaper") }
                    }.padding(.vertical,5)
                }
                if !library.shelfFilters.isEmpty {
                    Text("常用筛选").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,8)
                    ForEach(library.shelfFilters) { filter in
                        Button { applyFilter(filter) } label: { Label(filter.title,systemImage:"line.3.horizontal.decrease").lineLimit(1) }
                            .buttonStyle(.plain).padding(6).help(filter.title)
                            .contextMenu { Button("删除常用筛选",role:.destructive) { perform { try library.removeShelfFilter(filter.id) } } }
                    }
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
            if !periodicals.isEmpty {
                Menu("按刊物") { ForEach(periodicals,id:\.self) { name in Button(name) { scope = "periodical:"+name } } }
            }
            if !library.shelfFilters.isEmpty {
                Menu("常用筛选") { ForEach(library.shelfFilters) { filter in Button(filter.title) { applyFilter(filter) } } }
            }
            Button("新建专题…") { promptTopic() }
        } label: { Label(heading,systemImage:"line.3.horizontal.decrease") }
    }

    private func toolbar(_ books:[LibraryBook]) -> some View {
        VStack(alignment:.leading,spacing:8) {
            PanelRow {
                TextField("搜索书名、刊名、期次或标签",text:$query).textFieldStyle(.roundedBorder)
                Menu {
                    Button("添加书籍…") { ShelfChooser.open(title:"添加到个人书架",multiple:true,action:previewImport) }
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
                if scope == "queue" {
                    Button("下一份") { store.continueShelfQueue() }.disabled(library.nextShelfQueueBook() == nil)
                } else if periodical != nil {
                    Text("按年、卷、期排序").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("排序",selection:$sort) {
                        ForEach(ShelfSort.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                    }.fixedSize()
                }
                Button(filtering ? "筛选已启用" : "筛选") { showFilters.toggle() }.popover(isPresented:$showFilters) { filtersPopover }
                Button("需要处理的文件…") { showFiles = true }.disabled(library.books.isEmpty)
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

    private func browserCollection(_ books:[LibraryBook]) -> some View {
        ScrollViewReader { proxy in
            collection(books)
                .task(id:"\(grid)-\(scope)-\(page)") {
                    guard let focused, books.contains(where:{$0.id == focused}) else { return }
                    await Task.yield()
                    if !Task.isCancelled { proxy.scrollTo(focused,anchor:.center) }
                }
        }
    }

    private func queueRows(_ books:[LibraryBook]) -> some View {
        let queue = library.readingQueue
        return List(books) { book in
            HStack(spacing:10) {
                Image(systemName:"line.3.horizontal").foregroundStyle(.secondary)
                    .onDrag { NSItemProvider(object:book.id.uuidString as NSString) }
                    .help("拖动调整待读顺序")
                VStack(alignment:.leading,spacing:4) {
                    bookLabel(book,lines:1)
                    if library.catalog.queueCursor == book.id { Text("当前读到这里").font(.caption).foregroundStyle(Color.accentColor) }
                }
                Spacer()
                if let index = queue.firstIndex(where:{$0.id == book.id}) {
                    Button { perform { try library.moveShelfQueue(book.id,before:queue[index-1].id) } } label:{Image(systemName:"arrow.up")}
                        .buttonStyle(.borderless).disabled(index == 0).help("上移").accessibilityLabel("上移")
                    Button { perform { try library.moveShelfQueue(queue[index+1].id,before:book.id) } } label:{Image(systemName:"arrow.down")}
                        .buttonStyle(.borderless).disabled(index+1 >= queue.count).help("下移").accessibilityLabel("下移")
                }
                Button("阅读") { openQueued(book) }.buttonStyle(.borderless)
            }
            .padding(.vertical,5)
            .modifier(ShelfRowGestures(single:{focused = book.id},double:{openQueued(book)}))
            .contextMenu { bookActions(book) }
            .dropDestination(for:String.self) { values,_ in
                guard let id = values.first.flatMap(UUID.init(uuidString:)), queue.contains(where:{$0.id == id}), id != book.id else { return false }
                perform { try library.moveShelfQueue(id,before:book.id) }
                return true
            }
            .id(book.id)
        }
    }

    private var filtersPopover: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("书架筛选").font(.headline)
            TextField("年代",text:$filterYear)
            TextField("刊名",text:$filterPeriodical)
            Picker("阅读状态",selection:$filterStatus) {
                Text("不限").tag("")
                ForEach(ShelfReadingStatus.allCases) { status in Text(status.rawValue).tag(status.rawValue) }
            }
            Toggle("仅显示已有摘录的书",isOn:$filterExcerpts)
            HStack {
                Button("清空") { filterYear = "";filterPeriodical = "";filterStatus = "";filterExcerpts = false }
                Button("保存为常用筛选…") { showFilters = false;filterTitle = "";saveFilter = true }
            }
        }.padding(16).frame(width:295)
    }

    private func applyFilter(_ filter:ShelfSavedFilter) {
        scope = filter.scope
        query = filter.query
        matchedQuery = filter.query
        filterYear = filter.year
        filterPeriodical = filter.periodical
        filterStatus = filter.status?.rawValue ?? ""
        filterExcerpts = filter.withExcerpts
        page = 0
        focused = nil
    }

    private func storeFilter() {
        let title = filterTitle.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { message = "请输入筛选名称";return }
        var filter = ShelfSavedFilter(title:title,scope:scope,query:query,year:filterYear,
                                      periodical:filterPeriodical,status:ShelfReadingStatus(rawValue:filterStatus),withExcerpts:filterExcerpts)
        if let saved = library.shelfFilters.first(where:{$0.title == title}) { filter.id = saved.id }
        perform { try library.saveShelfFilter(filter);message = "已保存常用筛选" }
    }

    private func updateSummaries() async {
        let state = journal.state
        let work = Task.detached(priority:.utility) { ShelfRecordSummary.index(state) }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if !Task.isCancelled { summaries = result }
    }

    private func recordOverview(_ book:LibraryBook,_ summary:ShelfRecordSummary) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(["摘录","笔记","标注","PDF 评论"].map{"\($0) \(summary.counts[$0,default:0])"}.joined(separator:" · "))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(summary.recent) { item in
                let citation = item.citations053.first{ReadingBookIdentity.key($0.source.path) == ReadingBookIdentity.key(book.path)}
                Button { revealRecord(item,citation:citation) } label: {
                    HStack(spacing:6) {
                        Text(item.kind).foregroundStyle(.secondary)
                        Text(item.title).lineLimit(1)
                        if let citation { Text(citation.display).foregroundStyle(.secondary).lineLimit(1) }
                    }.font(.caption)
                }.buttonStyle(.plain)
                 .disabled(citation == nil)
                 .help("返回这条记录的原文")
            }
        }
    }

    private func revealRecord(_ item:ReadingLibraryItem,citation:ReadingCitation?) {
        guard let citation else { return }
        if case .record(let record) = item { sourceNavigator.open(citation,record:record,store:store) }
        else { _ = store.reveal(citation.source,beside:false) }
    }

    private func openQueued(_ book:LibraryBook) {
        focused = book.id
        Task {
            do { try await store.openShelfQueueBook(book) }
            catch where FolioCancellation.matches(error) {}
            catch { message = error.localizedDescription }
        }
    }

    @ViewBuilder private func collection(_ books:[LibraryBook]) -> some View {
        if books.isEmpty {
            VStack(spacing:8) {
                Image(systemName:"books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                Text(library.books.isEmpty ? "书架为空" : "没有匹配的书籍").font(.headline)
                if library.books.isEmpty { Text("通过「添加」或从访达拖入文献。").foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else if scope == "queue" {
            queueRows(books)
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
                         .id(book.id)
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
                 .id(book.id)
            }.listStyle(.inset)
        }
    }

    private func check(_ book:LibraryBook) -> some View {
        Toggle("选择",isOn:Binding(get:{selected.contains(book.id)},set:{ checked in
            if checked { selected.insert(book.id) } else { selected.remove(book.id) }
        })).labelsHidden().help("勾选 "+book.title)
    }

    private func bookLabel(_ book:LibraryBook,lines:Int) -> some View {
        let issue = book.issueMetadata
        let metadata = [book.shelfAuthor ?? "",issue.periodical,issue.year,
                        issue.volume.isEmpty ? "" : "卷 "+issue.volume,
                        issue.issue.isEmpty ? "" : "第 "+issue.issue+" 期"].filter{!$0.isEmpty}
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
                Button("续读") { if scope == "queue" { openQueued(book) } else { open(book) } }.buttonStyle(.borderedProminent)
                Button("本书记录") { showNotebook(book) }
                Button("导出记录…") { showNotebook(book,export:true) }
                if fileStatus[book.path] == .missing { Button("重新定位…") { relink(book) } }
                Spacer(minLength:0)
            }
            recordOverview(book,summaries[ReadingBookIdentity.key(book.path)] ?? ShelfRecordSummary())
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
        Button("继续阅读") { if scope == "queue" { openQueued(book) } else { open(book) } }
        if book.canQueueReading {
            if library.catalog.readingQueue?.contains(book.id) == true {
                Button("从待读队列移出") { perform { try library.dequeueShelfBook(book.id) } }
            } else { Button("加入待读队列") { perform { try library.enqueueShelfBooks([book.id]);message = "已加入待读队列" } } }
        }
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
        if ids.count > 1 {
            Button("加入待读队列") {
                perform { try library.enqueueShelfBooks(ShelfBrowse.ordered(library.books.filter{ids.contains($0.id) && $0.canQueueReading},sort:sort,progress:progress).map(\.id)) }
            }
        }
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
    private func previewImport(_ urls:[URL]) {
        var known = Set<URL>()
        let items = urls.filter{known.insert($0.standardizedFileURL).inserted}.map(ShelfImportDraft.init)
        if !items.isEmpty { importRequest = ShelfImportRequest(drafts:items) }
    }
    private func add(_ urls:[URL],bibliography:Bibliography? = nil,drafts:[ShelfImportDraft] = []) {
        message = "";query = "";matchedQuery = "";scope = "all";page = 0
        filterYear = "";filterPeriodical = "";filterStatus = "";filterExcerpts = false
        addition.add(urls,to:library,bibliography:bibliography,drafts:drafts)
    }
    private func open(_ book:LibraryBook) {
        guard !opening else { return }
        focused = book.id
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
                    relinkReview = review
                } catch { message = error.localizedDescription }
            }
        }
    }
    private func finishRelink(_ review:ShelfRelinkReview) {
        relinkReview = nil
        relinking = true
        Task {
            defer { relinking = false }
            do {
                let digest = try await Task.detached(priority:.utility) { try ShelfFileStatus.digest(review.url) }.value
                guard digest != nil, digest == review.digest,
                      library.books.contains(where:{$0.id == review.book.id && $0.path == review.book.path}) else {
                    throw FolioError(message:"文件或书架记录已变化，请重新核对")
                }
                try library.relink(path:review.book.path,to:review.url,defaults:store.readingDefaults,validated:true,verifiedDigest:digest)
                refresh = UUID();message = "已重新定位"
            } catch { message = error.localizedDescription }
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
