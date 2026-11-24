import SwiftUI

enum HomeWorkspaceLayout {
    static let maximumWidth: CGFloat = 980

    static func isCompact(width: CGFloat) -> Bool { width < 520 }

    static func horizontalInset(compact: Bool) -> CGFloat { compact ? 20 : 32 }
}

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
    @Environment(\.colorScheme) private var colorScheme

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
            let wide = geometry.size.width >= 760
            let compact = HomeWorkspaceLayout.isCompact(width: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                    header(wide: wide)
                    dashboard(wide: wide, compact: compact)
                    if lastRead == nil {
                        Label("将 PDF、图片或文本文件拖入窗口即可打开", appIcon: "arrow.down.to.line")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, HomeWorkspaceLayout.horizontalInset(compact: compact))
                .padding(.top, compact ? 22 : 38)
                .padding(.bottom, 32)
                .frame(maxWidth: HomeWorkspaceLayout.maximumWidth)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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

    private func header(wide: Bool) -> some View {
        let title = Text("阅读工作台")
            .font(.system(size: wide ? 32 : 27, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
        return Group {
            if wide {
                HStack(spacing: 16) { title; Spacer(); shortcuts }
            } else {
                VStack(alignment: .leading, spacing: 14) { title; shortcuts }
            }
        }
    }

    private var shortcuts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { shortcutButtons(compact: false) }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) { shortcutButtons(compact: true) }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { shortcutButtons(compact: true) }
        }
    }

    @ViewBuilder private func shortcutButtons(compact: Bool) -> some View {
        Button { store.openReadingHistory(.bookshelf) } label: {
            Label(compact ? "书架" : "个人书架", appIcon: "books.vertical")
        }.buttonStyle(HomeWorkspaceButtonStyle(.quiet))
        Button { store.openReadingDesk(.search, window: true) } label: {
            Label("资料库", appIcon: "tray.full")
        }.buttonStyle(HomeWorkspaceButtonStyle(.quiet))
        Button { workspace.open() } label: {
            Label("打开文件", appIcon: "folder")
        }.buttonStyle(HomeWorkspaceButtonStyle(lastRead == nil ? .accent : .quiet))
    }

    @ViewBuilder private func dashboard(wide: Bool, compact: Bool) -> some View {
        let batch = store.unfinishedHomeBatch
        let combined = batch?.sharesHomeResume(with: lastRead?.path) == true
        let note = ReadingLibraryItem.latestHomeNote(journal.state)
        let separateBatch = combined ? nil : batch
        let hasWork = note != nil || separateBatch?.next != nil || !store.startupEntries.isEmpty

        if let item = lastRead { resumeCard(item, batch: combined ? batch : nil, wide: wide, compact: compact) }
        if wide && hasWork {
            HStack(alignment: .top, spacing: 22) {
                workColumn(note: note, batch: separateBatch).frame(maxWidth: .infinity)
                utilityColumn.frame(width: 256)
            }
        } else {
            if hasWork { workColumn(note: note, batch: separateBatch) }
            utilityColumn
        }
        if resolving || sourceNavigator.busy {
            ProgressView().controlSize(.small).accessibilityLabel("正在准备文件")
        }
        if !message.isEmpty {
            Label(message, appIcon: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func workColumn(note: ReadingLibraryItem?, batch: ReadingOpenBatch?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("最近工作")
            if let note { noteCard(note) }
            if let batch, let next = batch.next { batchCard(batch, next: next) }
            if !store.startupEntries.isEmpty {
                panel {
                    entryHeading("上次标签页", symbol: "clock.arrow.circlepath", tint: .secondary)
                    Text("有 \(store.startupEntries.count) 份文献可恢复")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("查看上次标签页") { store.showStartupReview = true }
                        .buttonStyle(HomeWorkspaceButtonStyle(.soft))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var utilityColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("快速访问")
            if let search = lastSearch { searchCard(search) }
            foldersCard
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func entryHeading(_ title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            AppIcon(symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
        }.font(.system(size: 13, weight: .semibold))
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.08))
                    .allowsHitTesting(false)
            }
    }

    private func noteCard(_ note: ReadingLibraryItem) -> some View {
        let source = note.homeSource
        return panel {
            entryHeading("最近编辑的笔记", symbol: "square.and.pencil", tint: .purple)
            Text(note.homeNoteTitle).font(.system(size: 15, weight: .semibold))
                .lineLimit(2).help(note.homeNoteTitle)
            let reference = source?.1.display ?? "独立笔记"
            Text(reference).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(reference)
            if let preview = note.homeNotePreview, preview != note.homeNoteTitle {
                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(preview)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { noteActions(note, source: source) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) { noteActions(note, source: source) }
            }.padding(.top, 2)
        }
    }

    @ViewBuilder private func noteActions(_ note: ReadingLibraryItem, source: (ReadingRecord, ReadingCitation)?) -> some View {
        Button("继续写") { store.openReadingItem(note.id) }.buttonStyle(HomeWorkspaceButtonStyle(.soft))
        if let (record, citation) = source {
            Button("返回原文") { sourceNavigator.open(citation, record: record, store: store) }
                .buttonStyle(HomeWorkspaceButtonStyle(.quiet))
        }
    }

    private func batchCard(_ batch: ReadingOpenBatch, next: ReadingOpenBatch.Entry) -> some View {
        panel {
            entryHeading("继续批阅", symbol: "list.bullet.rectangle", tint: .teal)
            Text(HomeReadingDisplay.documentTitle(next.title)).font(.system(size: 15, weight: .semibold))
                .lineLimit(2).help(next.title)
            Text(batchSummary(batch)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: Double(batch.finishedCount), total: Double(max(1, batch.entries.count)))
                .tint(.teal).accessibilityLabel("批阅进度")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { batchActions(batch, next: next) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) { batchActions(batch, next: next) }
            }.padding(.top, 2)
        }
    }

    @ViewBuilder private func batchActions(_ batch: ReadingOpenBatch, next: ReadingOpenBatch.Entry) -> some View {
        Button("打开下一份") { store.openReadingBatchEntry(next) }.buttonStyle(HomeWorkspaceButtonStyle(.soft))
        Button("查看本批") { showBatch(batch) }.buttonStyle(HomeWorkspaceButtonStyle(.quiet))
    }

    private func searchCard(_ search: HomeReadingSearch) -> some View {
        panel {
            DisclosureGroup(isExpanded: $searchExpanded) {
                Text(search.title + (search.pdfMatch.map { " · 第 \($0.index + 1) 处" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.top, 4)
            } label: { entryHeading("上次搜索", symbol: "magnifyingglass", tint: Brand.accent) }
            Text(search.query).font(.callout.weight(.medium)).lineLimit(2).help(search.query)
            Button("恢复搜索") {
                resolving = true
                message = ""
                Task {
                    defer { resolving = false }
                    do { try await store.resumeHomeSearch(search) }
                    catch { message = error.localizedDescription }
                }
            }
            .buttonStyle(HomeWorkspaceButtonStyle(.soft))
            .disabled(resolving)
        }
    }

    private var foldersCard: some View {
        panel {
            DisclosureGroup(isExpanded: $foldersExpanded) {
                if store.homePinnedFolders.isEmpty {
                    Text("尚未固定文件夹").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.homePinnedFolders) { folder in
                            Divider()
                            folderRow(folder)
                        }
                    }.padding(.top, 4)
                }
            } label: {
                entryHeading("常用文件夹", symbol: "folder", tint: .orange)
            }
            if !foldersExpanded, !store.homePinnedFolders.isEmpty {
                Text(store.homePinnedFolders.map(\.title).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button {
                foldersExpanded = true
                store.chooseHomeFolders()
            } label: {
                Label("固定文件夹…", appIcon: "plus")
            }.buttonStyle(HomeWorkspaceButtonStyle(.quiet))
        }
    }

    private func folderRow(_ folder: HomePinnedFolder) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(folder.title).font(.callout.weight(.medium)).lineLimit(2).help(folder.path)
            Text(HomeReadingDisplay.folderLocation(folder.url))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(folder.path)
            HStack(spacing: 6) {
                Button("打开文件") { store.open(directory: folder.url) }
                    .buttonStyle(HomeWorkspaceButtonStyle(.soft))
                Menu {
                    Button("在访达中打开") {
                        if !NSWorkspace.shared.open(folder.url) { message = "找不到文件夹，可移除后重新固定。" }
                    }
                    Button("取消固定", role: .destructive) {
                        store.updateHomeFolders(store.homePinnedFolders.filter { $0.id != folder.id })
                    }
                } label: { AppIcon("ellipsis").frame(width: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("文件夹操作").accessibilityLabel("文件夹操作")
            }
        }
    }

    private func resumeCard(_ item: ReadingProgress.HistoryItem, batch: ReadingOpenBatch?, wide: Bool, compact: Bool) -> some View {
        let pageLabel = store.research.label(path: item.path, page: item.progress.last) ?? item.progress.pageLabel
        let phase = preparation.path.map(ReadingBookIdentity.key) == ReadingBookIdentity.key(item.path) ? preparation.phase : nil
        let title = HomeReadingDisplay.documentTitle(store.library.book(path: item.path)?.title ?? item.title)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                if !compact {
                    LibraryCover(path: item.path)
                        .frame(width: 72, height: 96)
                        .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Label("继续阅读", appIcon: "book")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.76, green: 0.86, blue: 1))
                        .accessibilityAddTraits(.isHeader)
                    Text(title).font(.system(size: compact ? 20 : 25, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(3).help(item.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(HomeReadingDisplay.pagePosition(item.progress, printedLabel: pageLabel))
                        if let batch { Text(batchSummary(batch)) }
                    }
                    .font(.callout).foregroundStyle(Color.white.opacity(0.82))
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    resumeActions(item, batch: batch, phase: phase).fixedSize(horizontal: true, vertical: false)
                }
            }
            if let status = resumeStatus(phase) {
                HStack(spacing: 7) {
                    if phase?.inProgress == true { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.white)
                }.accessibilityElement(children: .combine)
            }
            if !wide { resumeActions(item, batch: batch, phase: phase) }
        }
        .padding(compact ? 18 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [
                    Color(red: 0.08, green: 0.15, blue: 0.26),
                    Color(red: 0.12, green: 0.25, blue: 0.44)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .environment(\.colorScheme, .dark)
    }

    private func resumeActions(_ item: ReadingProgress.HistoryItem, batch: ReadingOpenBatch?, phase: HomeReadingPreparation.Phase?) -> some View {
        HStack(spacing: 8) {
            Group {
                switch phase {
                case .locating, .downloading:
                    Button("取消") { preparation.cancel() }
                case .missing:
                    Button("重新定位…") { chooseReplacement(item) }
                default:
                    Button { resume(item, batch: batch) } label: {
                        Label(phase == .ready ? "打开文件" : "继续阅读", appIcon: "arrow.right")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }.buttonStyle(HomeWorkspaceButtonStyle(.hero))
            Menu {
                if let batch { Button("查看本批") { showBatch(batch) } }
                Button("重新定位原文件…") { chooseReplacement(item) }
            } label: {
                AppIcon("ellipsis", tone: AppIcon.onAccent)
                    .frame(width: 30, height: 28)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("续读操作").accessibilityLabel("续读操作")
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

private struct HomeWorkspaceButtonStyle: ButtonStyle {
    enum Role: Equatable { case quiet, soft, accent, hero }
    let role: Role

    init(_ role: Role) { self.role = role }

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled && (configuration.isPressed || hovering)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(minHeight: role == .hero ? 34 : 30)
            .background(background(active), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(role == .quiet ? Color.primary.opacity(0.13) : .clear)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch role {
        case .quiet: return .primary
        case .soft: return .primary
        case .accent: return .white
        case .hero: return Color(red: 0.08, green: 0.15, blue: 0.26)
        }
    }

    private func background(_ active: Bool) -> Color {
        switch role {
        case .quiet: return Color.primary.opacity(active ? 0.08 : 0.025)
        case .soft: return Brand.accent.opacity(active ? 0.22 : 0.12)
        case .accent: return Color(red: 0.14, green: 0.33, blue: active ? 0.66 : 0.76)
        case .hero: return .white.opacity(active ? 0.86 : 1)
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
