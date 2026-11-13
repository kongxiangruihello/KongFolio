import SwiftUI

struct HomeReadingView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var journal: ReadingJournal
    @State private var lastRead: ReadingProgress.HistoryItem?
    @State private var lastSearch: HomeReadingSearch?
    @State private var missingBook: ReadingProgress.HistoryItem?
    @State private var relinkReview: ShelfRelinkReview?
    @State private var resolving = false
    @State private var message = ""
    @State private var historyRevision = UUID()
    @StateObject private var sourceNavigator = ReadingSourceNavigator()

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if let item = lastRead {
                let label = (store.research.label(path:item.path,page:item.progress.last) ?? item.progress.pageLabel).map { " · 印刷页码 " + $0 } ?? ""
                row("继续阅读",icon:"book",title:item.title,detail:"PDF 第 \(item.progress.last + 1) 页" + label) {
                    Button("继续阅读") { resume(item) }.disabled(resolving)
                    Menu {
                        Button("重新定位原文件…") { chooseReplacement(item) }
                    } label: { Image(systemName:"ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("阅读文件操作")
                }
            }
            if let batch = store.unfinishedHomeBatch, let next = batch.next {
                row("继续批阅",icon:"list.bullet.rectangle",title:next.title,
                    detail:"已读完 \(batch.finishedCount)/\(batch.entries.count) 份 · 待读 \(batch.pendingCount) 份") {
                    Button("打开下一份") { store.openReadingBatchEntry(next) }
                    Button("查看本批") {
                        store.selectedReadingBatchID = batch.id
                        store.showReadingBatch = true
                    }
                }
            }
            if let note = ReadingLibraryItem.latestHomeNote(journal.state) {
                let source = note.homeSource
                row("继续写笔记",icon:"square.and.pencil",title:note.title,detail:source?.1.display ?? "独立笔记") {
                    Button("继续写") { store.openReadingItem(note.id) }
                    if let (record,citation) = source {
                        Button("返回原文") { openSource(record,citation) }
                    }
                }
            }
            if let search = lastSearch {
                row("上次搜索",icon:"magnifyingglass",title:search.query,
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
            }
            HStack {
                Label("常用文件夹",systemImage:"folder").font(.subheadline.weight(.medium))
                Spacer()
                Button("固定文件夹…") { store.chooseHomeFolders() }
            }
            .padding(.vertical,10)
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
            if resolving || sourceNavigator.busy { ProgressView().controlSize(.small).padding(.vertical,6) }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(.vertical,6)
            }
        }
        .modifier(HomeSourceSheet(navigator:sourceNavigator,store:store))
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
        .alert("找不到上次阅读的文件",isPresented:Binding(get:{ missingBook != nil },set:{ if !$0 { missingBook = nil } })) {
            if let item = missingBook {
                Button("重新定位…") { chooseReplacement(item) }
            }
            Button("取消",role:.cancel) {}
        } message: { Text(missingBook?.path ?? "") }
        .alert("重新关联阅读文件",isPresented:Binding(get:{ relinkReview != nil },set:{ if !$0 { relinkReview = nil } })) {
            if let review = relinkReview {
                Button("确认关联") { finishRelink(review) }
            }
            Button("取消",role:.cancel) {}
        } message: { Text(relinkReview?.message ?? "") }
    }

    private func row<Actions: View>(_ heading: String?,icon: String,title: String,detail: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing:0) {
            Divider()
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) {
                    rowLabel(heading,icon:icon,title:title,detail:detail)
                    Spacer(minLength:6)
                    HStack(spacing:6,content:actions).fixedSize()
                }
                VStack(alignment:.leading,spacing:6) {
                    rowLabel(heading,icon:icon,title:title,detail:detail)
                    HStack(spacing:6,content:actions).padding(.leading,28)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            .padding(.vertical,8)
        }
    }

    private func rowLabel(_ heading: String?,icon: String,title: String,detail: String) -> some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:icon).foregroundStyle(Brand.accent).frame(width:19).padding(.top,2)
            VStack(alignment:.leading,spacing:3) {
                if let heading { Text(heading).font(.caption).foregroundStyle(.secondary) }
                Text(title).font(.callout.weight(.medium)).lineLimit(1).help(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
            }.frame(minWidth:100,alignment:.leading)
        }
    }

    private func resume(_ item: ReadingProgress.HistoryItem) {
        let shortcut = store.library.resolve(ReadingShortcut(path:item.path,title:item.title,position:ViewPosition(selection:0),bookmark:item.progress.bookmark))
        let origin = store.selectedID
        message = ""
        resolving = true
        Task {
            defer { resolving = false }
            do {
                let url = try await Task.detached(priority:.utility) { try shortcut.resolvedURL() }.value
                guard origin == store.selectedID, store.activeWorkspace?.displayPath == nil else { return }
                do { try store.continueHomeReading(item,resolvedFile:url) }
                catch { message = error.localizedDescription }
            } catch { missingBook = item }
        }
    }

    private func chooseReplacement(_ item: ReadingProgress.HistoryItem) {
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
                historyRevision = UUID()
                let item = ReadingProgress.HistoryItem(path:review.url.path,progress:ReadingProgress.load(path:review.url.path,defaults:store.readingDefaults))
                try store.continueHomeReading(item,resolvedFile:review.url)
            } catch { message = error.localizedDescription }
        }
    }

    private func openSource(_ record: ReadingRecord,_ citation: ReadingCitation) {
        sourceNavigator.open(citation,record:record,store:store)
    }

}

private struct HomeSourceSheet: ViewModifier {
    @ObservedObject var navigator: ReadingSourceNavigator
    let store: WorkspaceStore
    func body(content: Content) -> some View {
        content.sheet(item:$navigator.review,onDismiss:{ navigator.cancel() }) { request in
            ReadingSourceReviewSheet(request:request,navigator:navigator,store:store).id(request.id)
        }
    }
}
