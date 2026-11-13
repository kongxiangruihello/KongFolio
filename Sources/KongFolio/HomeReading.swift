import AppKit

struct HomeReadingSearch: Codable, Equatable {
    enum Scope: String, Codable { case pdf, library, excerpts, notes }

    var scope: Scope
    var query: String
    var path: String? = nil
    var pdfMatch: PDFMatch? = nil
    var record: ReadingLibraryID? = nil
    var librarySession: ReadingLibrarySession? = nil
    var libraryOptions: ReadingLibraryOptions053? = nil
    var deskFilter: DeskFilter? = nil

    struct PDFMatch: Codable, Equatable {
        var page: Int
        var range: NSRange
        var strips: [CGRect]?
        var index: Int
    }

    struct DeskFilter: Codable, Equatable {
        var source: ReadingDeskSourceFilter
        var tag: String
        var recent: Bool
        var removed: Bool
    }

    var title: String {
        switch scope {
        case .pdf: return "当前 PDF 正文"
        case .library: return libraryOptions?.scope.rawValue ?? "全部阅读资料"
        case .excerpts: return deskTitle("摘录")
        case .notes: return deskTitle("笔记")
        }
    }

    private func deskTitle(_ kind: String) -> String {
        switch deskFilter?.source {
        case .book: return "当前书的" + kind
        case .independent: return "独立笔记"
        default: return "全部" + kind
        }
    }

    static let key = "KongFolio.homeReadingSearch"
    static func load(_ defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey:key) else { return nil }
        return try? JSONDecoder().decode(Self.self,from:data)
    }

    func save(_ defaults: UserDefaults) {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data,forKey:Self.key)
    }
}

struct HomeSearchRequest: Equatable {
    let id = UUID()
    let search: HomeReadingSearch
}

struct HomePinnedFolder: Codable, Identifiable, Equatable {
    static let key = "KongFolio.homePinnedFolders"
    var path: String
    var id: String { ReadingBookIdentity.key(path) }
    var url: URL { URL(fileURLWithPath:path,isDirectory:true) }
    var title: String { url.lastPathComponent.isEmpty ? path : url.lastPathComponent }

    static func load(_ defaults: UserDefaults) -> [Self] {
        guard let data = defaults.data(forKey:key) else { return [] }
        return (try? JSONDecoder().decode([Self].self,from:data)) ?? []
    }
}

extension ReadingLibraryItem {
    static func latestHomeNote(_ state: ReadingJournalState) -> Self? {
        let record = state.records.lazy.filter { $0.kind == .note && $0.removed == nil && $0.hasContent }
            .max { ($0.modified,$0.id.uuidString) < ($1.modified,$1.id.uuidString) }
        let essay = state.essays.lazy.filter { $0.removed == nil && $0.hasContent }
            .max { ($0.modified,$0.id.uuidString) < ($1.modified,$1.id.uuidString) }
        if let essay, record.map({ $0.modified <= essay.modified }) ?? true { return .essay(essay) }
        return record.map(Self.record)
    }

    var homeSource: (ReadingRecord,ReadingCitation)? {
        switch self {
        case .record(let record):
            return record.citations053.first { !$0.source.path.isEmpty }.map { (record,$0) }
        case .essay(let essay):
            for record in essay.blocks.compactMap(\.record) {
                if let citation = record.citations053.first(where:{ !$0.source.path.isEmpty }) { return (record,citation) }
            }
            return citations053.first { !$0.source.path.isEmpty }.map { (ReadingRecord(kind:.note,citations:[$0]),$0) }
        }
    }
}

extension WorkspaceStore {
    var unfinishedHomeBatch: ReadingOpenBatch? { readingBatches.first { $0.next != nil } }

    func updateHomeFolders(_ folders: [HomePinnedFolder]) {
        guard folders != homePinnedFolders, let data = try? JSONEncoder().encode(folders) else { return }
        readingDefaults.set(data,forKey:HomePinnedFolder.key)
        homePinnedFolders = folders
    }

    func chooseHomeFolders() {
        guard !DocumentOpenPanel.coordinator.revealExisting() else { return }
        let panel = NSOpenPanel()
        DocumentOpenPanel.configure(panel)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "固定常用文件夹"
        panel.prompt = "固定"
        panel.message = "选择要放在首页的文献文件夹。"
        DocumentOpenPanel.coordinator.present(panel,presentation:.separate) { [weak self] _,urls in
            guard let self else { return }
            var seen = Set(self.homePinnedFolders.map(\.id))
            let new = urls.filter(\.isFileURL).map { HomePinnedFolder(path:$0.path) }.filter { seen.insert($0.id).inserted }
            self.updateHomeFolders(self.homePinnedFolders + new)
        }
    }

    func continueHomeReading(_ item: ReadingProgress.HistoryItem, resolvedFile: URL? = nil) throws {
        let progress = item.progress
        let position = progress.resumePosition(pageCount:max(progress.pages,progress.last + 1)) ?? ViewPosition(selection:0)
        let shortcut = ReadingShortcut(path:item.path,title:item.title,position:position,layout:progress.layout,bookmark:progress.bookmark)
        try openReadingShortcut(shortcut,resolvedFile:resolvedFile)
    }

    func resumeHomeSearch(_ search: HomeReadingSearch) async throws {
        if search.scope == .library {
            readingLibraryNavigation = nil
            readingLibraryPreferredKind = nil
            homeSearchRequest = HomeSearchRequest(search:search)
            openReadingDesk(.search,window:true)
            return
        }

        var workspace = activeWorkspace
        if let path = search.path {
            let progress = ReadingProgress.load(path:path,defaults:readingDefaults)
            let position = ViewPosition(selection:search.pdfMatch?.page ?? progress.last)
            let shortcut = library.resolve(ReadingShortcut(path:path,title:URL(fileURLWithPath:path).lastPathComponent,
                                                           position:position,bookmark:progress.bookmark))
            let origin = selectedID
            let url = try await Task.detached(priority:.utility) { try shortcut.resolvedURL() }.value
            guard origin == selectedID, !Task.isCancelled else { return }
            workspace = try openReadingShortcut(shortcut,resolvedFile:url)
        }
        if search.scope == .pdf {
            guard let workspace, workspace.displayPath != nil else { return }
            let match = search.pdfMatch
            let restore = PDFSearchResume(query:search.query,executedQuery:search.query,page:match?.page,
                                          range:match?.range,strips:match?.strips,revealMatch:true)
            rememberRightPanelNote()
            showReadingDesk = false
            lastRightPanelWasSearch = true
            pdfSearchWorkspaceID = workspace.id
            workspace.searchResume = restore
            workspace.resumePDFSearchIfNeeded()
        } else {
            let section: ReadingDeskSection = search.scope == .notes ? .notes : .excerpts
            showReadingPanel(section)
            homeSearchRequest = HomeSearchRequest(search:search)
        }
    }
}
