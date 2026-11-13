import SwiftUI

struct HomeReadingView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var journal: ReadingJournal
    let workspace: Workspace
    @ObservedObject var preparation: HomeReadingPreparation
    @State private var lastRead: ReadingProgress.HistoryItem?
    @State private var lastSearch: HomeReadingSearch?
    @State private var relinkReview: ShelfRelinkReview?
    @State private var resolving = false
    @State private var message = ""
    @State private var historyRevision = UUID()
    @AppStorage private var searchExpanded: Bool
    @AppStorage private var foldersExpanded: Bool
    @StateObject private var sourceNavigator = ReadingSourceNavigator()

    init(store: WorkspaceStore,journal: ReadingJournal,workspace: Workspace) {
        self.store = store
        self.journal = journal
        self.workspace = workspace
        preparation = store.homeReadingPreparation
        _searchExpanded = AppStorage(wrappedValue:false,"KongFolio.homeSearchExpanded",store:store.readingDefaults)
        _foldersExpanded = AppStorage(wrappedValue:false,"KongFolio.homeFoldersExpanded",store:store.readingDefaults)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 540 || geometry.size.width < 460
            ScrollView {
                VStack(spacing:compact ? 14 : 22) {
                    welcomeBrand(compact:compact)
                    WelcomeActions(workspace:workspace)
                    readingRows.frame(maxWidth:640)
                    if lastRead == nil {
                        Text("PDF · 图片 · Markdown · HTML · TXT · 可直接拖入窗口")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal,14)
                .padding(.top,compact ? 18 : min(68,max(32,geometry.size.height * 0.07)))
                .padding(.bottom,24)
                .frame(maxWidth:.infinity,minHeight:geometry.size.height,alignment:lastRead == nil ? .center : .top)
            }
        }
        .modifier(ReadingSourceSheetPresenter(navigator:sourceNavigator,store:store))
        .task(id:historyRevision) {
            lastSearch = HomeReadingSearch.load(store.readingDefaults)
            let snapshot = store.readingDefaults.dictionaryRepresentation()
            let recent = await Task.detached(priority:.utility) {
                ReadingProgress.history(snapshot:snapshot).first {
                    ["pdf","kongfolio"].contains(URL(fileURLWithPath:$0.path).pathExtension.lowercased())
                }
            }.value
            if !Task.isCancelled { lastRead = recent }
        }
        .onReceive(NotificationCenter.default.publisher(for:UserDefaults.didChangeNotification,object:store.readingDefaults)) { _ in
            lastSearch = HomeReadingSearch.load(store.readingDefaults)
        }
        .alert("重新关联阅读文件",isPresented:Binding(get:{ relinkReview != nil },set:{ if !$0 { relinkReview = nil } })) {
            if let review = relinkReview {
                Button("确认关联") { finishRelink(review) }
            }
            Button("取消",role:.cancel) {}
        } message: { Text(relinkReview?.message ?? "") }
    }

    private func welcomeBrand(compact: Bool) -> some View {
        VStack(spacing:compact ? 7 : 12) {
            Image(systemName:"doc.richtext")
                .font(.system(size:compact ? 38 : 54,weight:.ultraLight))
                .foregroundStyle(Brand.accent)
                .accessibilityHidden(true)
            Text("每一页，都井井有条。")
                .font(.system(size:compact ? 20 : 28,weight:.medium))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var readingRows: some View {
        let batch = store.unfinishedHomeBatch
        let combined = batch?.sharesHomeResume(with:lastRead?.path) == true
        return VStack(alignment:.leading,spacing:0) {
            if let item = lastRead {
                resumeRow(item,batch:combined ? batch : nil)
            }
            if let note = ReadingLibraryItem.latestHomeNote(journal.state) {
                let source = note.homeSource
                row("最近编辑的笔记",icon:"square.and.pencil",title:note.homeNoteTitle,
                    detail:source?.1.display ?? "独立笔记",
                    preview:note.homeNotePreview == note.homeNoteTitle ? nil : note.homeNotePreview) {
                    Button("继续写") { store.openReadingItem(note.id) }
                    if let (record,citation) = source {
                        Button("返回原文") { sourceNavigator.open(citation,record:record,store:store) }
                    }
                }
            }
            if !combined, let batch, let next = batch.next {
                row("继续批阅",icon:"list.bullet.rectangle",title:next.title,detail:batchSummary(batch)) {
                    Button("打开下一份") { store.openReadingBatchEntry(next) }
                    Button("查看本批") { showBatch(batch) }
                }
            }
            if let search = lastSearch {
                Divider()
                DisclosureGroup(isExpanded:$searchExpanded) {
                    row(nil,icon:"magnifyingglass",title:search.query,
                        detail:search.title + (search.pdfMatch.map { " · 第 \($0.index + 1) 处" } ?? "")) {
                        Button("恢复搜索") {
                            resolving = true
                            message = ""
                            Task {
                                defer { resolving = false }
                                do { try await store.resumeHomeSearch(search) }
                                catch { message = error.localizedDescription }
                            }
                        }.disabled(resolving)
                    }
                } label: {
                    Label("上次搜索",systemImage:"magnifyingglass")
                }.padding(.vertical,8)
            }
            Divider()
            DisclosureGroup(isExpanded:$foldersExpanded) {
                folderRows
            } label: {
                HStack {
                    Label("常用文件夹",systemImage:"folder")
                    Spacer(minLength:4)
                    Button("固定文件夹…") {
                        foldersExpanded = true
                        store.chooseHomeFolders()
                    }.fixedSize()
                }
            }.padding(.vertical,8)
            if resolving || sourceNavigator.busy { ProgressView().controlSize(.small).padding(.vertical,6) }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(.vertical,6)
            }
        }
    }

    private var folderRows: some View {
        ForEach(store.homePinnedFolders) { folder in
            row(nil,icon:"folder",title:folder.title,detail:folder.path) {
                Button("打开文件") { store.open(directory:folder.url) }
                Menu {
                    Button("在访达中打开") {
                        if !NSWorkspace.shared.open(folder.url) { message = "找不到文件夹，可移除后重新固定。" }
                    }
                    Button("取消固定",role:.destructive) {
                        store.updateHomeFolders(store.homePinnedFolders.filter { $0.id != folder.id })
                    }
                } label: { Image(systemName:"ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("文件夹操作")
            }
        }
    }

    private func resumeRow(_ item: ReadingProgress.HistoryItem,batch: ReadingOpenBatch?) -> some View {
        let label = (store.research.label(path:item.path,page:item.progress.last) ?? item.progress.pageLabel)
            .map { " · 印刷页码 " + $0 } ?? ""
        let phase = preparation.path.map(ReadingBookIdentity.key) == ReadingBookIdentity.key(item.path) ? preparation.phase : nil
        let detail = "PDF 第 \(item.progress.last + 1) 页" + label
        return row("继续阅读",icon:"book",title:item.title,detail:detail,
                   preview:batch.map(batchSummary),prominent:true,status:resumeStatus(phase),working:phase?.inProgress == true) {
            switch phase {
            case .locating, .downloading:
                Button("取消") { preparation.cancel() }
            case .missing:
                Button("重新定位…") { chooseReplacement(item) }.buttonStyle(.borderedProminent)
            default:
                Button(phase == .ready ? "打开文件" : "继续阅读") { resume(item,batch:batch) }.buttonStyle(.borderedProminent)
            }
            Menu {
                if let batch { Button("查看本批") { showBatch(batch) } }
                Button("重新定位原文件…") { chooseReplacement(item) }
            } label: { Image(systemName:"ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().help("续读操作")
        }
    }

    private func resumeStatus(_ phase: HomeReadingPreparation.Phase?) -> String? {
        switch phase {
        case .locating: return "正在查找文件…"
        case .downloading(let text): return text
        case .ready: return "文件已准备好"
        case .missing: return "找不到原文件，可能已移动。"
        case .failed(let text): return text
        case nil: return nil
        }
    }

    private func batchSummary(_ batch: ReadingOpenBatch) -> String {
        "已读完 \(batch.finishedCount)/\(batch.entries.count) 份 · 待读 \(batch.pendingCount) 份"
    }

    private func showBatch(_ batch: ReadingOpenBatch) {
        store.selectedReadingBatchID = batch.id
        store.showReadingBatch = true
    }

    private func row<Actions: View>(_ heading: String?,icon: String,title: String,detail: String,
                                    preview: String? = nil,prominent: Bool = false,
                                    status: String? = nil,working: Bool = false,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment:.leading,spacing:0) {
            if !prominent { Divider() }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) {
                    rowLabel(heading,icon:icon,title:title,detail:detail,preview:preview,prominent:prominent)
                        .frame(idealWidth:200,maxWidth:.infinity,alignment:.leading)
                    Spacer(minLength:6)
                    HStack(spacing:6,content:actions).fixedSize()
                }
                VStack(alignment:.leading,spacing:6) {
                    rowLabel(heading,icon:icon,title:title,detail:detail,preview:preview,prominent:prominent)
                    HStack(spacing:6,content:actions).padding(.leading,28)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if let status {
                HStack(spacing:6) {
                    if working { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading,28).padding(.top,6)
                .accessibilityElement(children:.combine)
            }
        }
        .padding(.vertical,prominent ? 12 : 4)
        .padding(.horizontal,prominent ? 12 : 0)
        .background {
            if prominent { RoundedRectangle(cornerRadius:10).fill(Brand.accent.opacity(0.09)) }
        }
    }

    private func rowLabel(_ heading: String?,icon: String,title: String,detail: String,preview: String?,prominent: Bool) -> some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:icon).foregroundStyle(Brand.accent).frame(width:19).padding(.top,2)
            VStack(alignment:.leading,spacing:3) {
                if let heading { Text(heading).font(.caption).foregroundStyle(.secondary) }
                Text(title).font(prominent ? .headline : .callout.weight(.medium)).lineLimit(1).help(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
                if let preview { Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(preview) }
            }.frame(minWidth:100,alignment:.leading)
        }
    }

    private func resume(_ item: ReadingProgress.HistoryItem,batch: ReadingOpenBatch?) {
        let shortcut = store.library.resolve(ReadingShortcut(path:item.path,title:item.title,position:ViewPosition(selection:0),bookmark:item.progress.bookmark))
        message = ""
        preparation.start(shortcut,trackedPath:item.path,prepare:workspace.prepareImportFiles) { [weak store,weak workspace] url in
            guard let store, let workspace, store.activeWorkspace === workspace, workspace.displayPath == nil,
                  !store.showReadingHistory, !store.showReadingBatch,
                  DocumentOpenPanel.coordinator.panel == nil,
                  NSApp.keyWindow?.identifier?.rawValue != "reading-desk" else { return false }
            let target = try store.continueHomeReading(item,resolvedFile:url)
            if let batch, batch.sharesHomeResume(with:item.path), let entry = batch.next,
               store.readingBatches.first(where:{ $0.id == batch.id })?.next?.id == entry.id {
                store.selectedReadingBatchID = batch.id
                if entry.path != url.path { store.updateBatchEntry(entry.id) { $0.path = url.path } }
                target.readingBatchEntryID = entry.id
                store.trackBatchSelection(target)
            }
            return true
        }
    }

    private func chooseReplacement(_ item: ReadingProgress.HistoryItem) {
        if preparation.phase?.inProgress == true { preparation.cancel() }
        let book = store.library.book(path:item.path) ?? LibraryBook(path:item.path,title:item.title,bookmark:item.progress.bookmark)
        ShelfChooser.open(title:"重新定位阅读文件",multiple:false) { urls in
            guard let url = urls.first else { return }
            resolving = true
            Task {
                defer { resolving = false }
                do {
                    let review = try await Task.detached(priority:.utility) { try ShelfRelinkReview.inspect(book,url:url) }.value
                    if review.verified { finishRelink(review) }
                    else { relinkReview = review }
                } catch { message = error.localizedDescription }
            }
        }
    }

    private func finishRelink(_ review: ShelfRelinkReview) {
        resolving = true
        Task {
            defer { resolving = false }
            do {
                let digest = try await Task.detached(priority:.utility) { try ShelfFileStatus.digest(review.url) }.value
                guard let digest, digest == review.digest else { throw FolioError(message:"文件已变化，请重新选择。") }
                try store.library.relink(path:review.book.path,to:review.url,defaults:store.readingDefaults,validated:true,verifiedDigest:digest)
                if let batch = store.unfinishedHomeBatch, batch.sharesHomeResume(with:review.book.path), let entry = batch.next {
                    store.updateBatchEntry(entry.id) { $0.path = review.url.path }
                }
                historyRevision = UUID()
                let item = ReadingProgress.HistoryItem(path:review.url.path,progress:ReadingProgress.load(path:review.url.path,defaults:store.readingDefaults))
                if store.activeWorkspace === workspace, workspace.displayPath == nil {
                    resume(item,batch:store.unfinishedHomeBatch)
                }
            } catch { message = error.localizedDescription }
        }
    }

}

struct ReadingSourceSheetPresenter: ViewModifier {
    @ObservedObject var navigator: ReadingSourceNavigator
    let store: WorkspaceStore
    func body(content: Content) -> some View {
        content.sheet(item:$navigator.review,onDismiss:{ navigator.cancel() }) { request in
            ReadingSourceReviewSheet(request:request,navigator:navigator,store:store).id(request.id)
        }
    }
}
