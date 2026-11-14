import AppKit
import PDFKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// One tab: a PDF/image document workspace or a Markdown note being edited.
@MainActor enum OpenTab: @preconcurrency Identifiable {
    case document(Workspace)
    case note(MarkdownNote)

    var id: UUID {
        switch self {
        case .document(let workspace): return workspace.id
        case .note(let note): return note.id
        }
    }
    var workspace: Workspace? { if case .document(let workspace) = self { return workspace } else { return nil } }
    var note: MarkdownNote? { if case .note(let note) = self { return note } else { return nil } }
    /// Fires when the tab's content changes, so menus that depend on the active tab refresh.
    var changes: AnyPublisher<Void, Never> {
        switch self {
        case .document(let workspace): return workspace.objectWillChange.eraseToAnyPublisher()
        case .note(let note): return note.objectWillChange.eraseToAnyPublisher()
        }
    }
}

/// Owns the open tabs. A document that is already open is never replaced: new files open in a new tab
/// (see `Workspace.load`), and every tab keeps its own recovery copy.
@MainActor final class WorkspaceStore: ObservableObject {
    @Published private(set) var tabs: [OpenTab] = []
    @Published private(set) var selectedID: UUID?
    static let readingModeKey = "KongFolio.focusedReadingMode"
    @Published var readingMode = true { didSet { readingDefaults.set(readingMode,forKey:Self.readingModeKey) } }
    @Published var showReadingDesk = false
    @Published var pdfSearchWorkspaceID: UUID?
    var lastRightPanelWasSearch = false
    var lastRightPanelNoteID: UUID?
    @Published var readingImageOCRRequest: ReadingImageOCRRequest?
    var pendingPDFExcerptDrag: PDFExcerptDrag?
    @Published var readingExcerptFeedback: ReadingExcerptFeedback?
    var readingExcerptUndo: ReadingExcerptUndo?
    var lastTextExcerptID: UUID?

    var readingDeskWindowSection = ReadingDeskSection.search
    @Published var readingDeskSection = ReadingDeskSection.excerpts
    @Published var showQuickReadingNote = false
    @Published var readingEssayBlockID:UUID?
    @Published var readingLibraryPreferredKind:String?
    @Published var readingLibraryNavigation:ReadingLibraryID?
    @Published var readingLibraryNavigationRequest = UUID()
    @Published var writingSearchHit:ReadingTextHit?
    @Published var writingSearchRequest = UUID()
    @Published var pinnedReadingID:UUID?
    let linkedSourceNavigator = ReadingSourceNavigator()
    @Published var quickExcerptNoteID:UUID?
    @Published var readingDetailRequest: ReadingDetailRequest?
    @Published var readingRecordID:UUID?
    @Published var multiRegionTarget053:UUID?
    @Published var readingRecordSelection = Set<UUID>() {
        didSet {
            readingRecordSelectionOrder.removeAll { !readingRecordSelection.contains($0) }
            let additions = readingRecordSelection.subtracting(oldValue)
            if additions.count == 1 { readingRecordSelectionOrder.append(contentsOf:additions) }
            else if !additions.isEmpty {
                let known = journal.state.records.map(\.id).filter { additions.contains($0) }
                readingRecordSelectionOrder.append(contentsOf:known+additions.subtracting(known).sorted { $0.uuidString < $1.uuidString })
            }
        }
    }
    private(set) var readingRecordSelectionOrder: [UUID] = []
    var readingLibraryExportOrder: [ReadingLibraryID] = []
    @Published var readingExportEssay = false
    @Published var readingDeskWindowRequest:UUID?
    var shelfQueueTab: UUID?
    var stagedShelfTab: UUID?
    @Published var shelfQueueProblem: ShelfQueueProblem?
    @Published var shelfQueueOpening = false
    @Published var shelfQueueReadingTab: UUID?
    lazy var journal = ReadingJournal(storage:storage)
    lazy var readingExportBatch = ReadingExportBatch()
    lazy var readingPackage = ReadingPackageController()
    var readingLibraryExportSelection:Set<ReadingLibraryID> = []
    @Published var showResearch = false
    var startupSafetyEnabled = !AppEnvironment.isTestRun
    @Published var showStartupReview = false
    @Published var showReadingSettings = false
    lazy var incrementalExport = ReadingIncrementalController()
    @Published var startupEntries: [SessionEntry] = []
    @Published var startupSuspects: [String:Int] = [:]
    @Published var pendingStartupSelected: String?
    private var sessionSaveTask: Task<Void,Never>?
    var runtimeTimer: DispatchSourceTimer?
    @Published var residentMemoryMB = 0
    @Published var constrainedMemory = false
    lazy var research = ResearchStore(storage: storage)
    let storage: URL
    let readingDefaults: UserDefaults
    let homeReadingPreparation = HomeReadingPreparation()
    @Published var homePinnedFolders: [HomePinnedFolder]
    @Published var homeSearchRequest: HomeSearchRequest?
    @Published var showReadingHistory = false
    @Published var libraryTab = ReadingHistoryPage.bookshelf.rawValue
    @Published var showHistorySettings = false
    @Published var notebookBook: LibraryBook?
    let library: BookLibrary
    /// The workspace shared by every tab: excerpts from any open document gather here.
    let board: Board
    let documentTasks: DocumentTaskQueue
    @Published var showBackgroundJobs = false
    @Published var showSignatureManager = false
    @Published var exportReview: ExportReviewRequest?
    @Published var showRecoveryCenter = false
    var pendingRecoveryURL: URL?
    let batchQueue: BatchQueue
    let folderSearch: FolderSearchModel
    @Published var pendingPageTransfer: PageTransferRequest?
    @Published var showTaskCenter = false
    @Published var showFolderSearch = false
    @Published var showDocumentComparison = false
    var showOCRTasksAfterSearch = false
    @Published var bookSearchRequest: BookSearchRequest?
    @Published var showReadingBatch = false
    @Published var readingBatches: [ReadingOpenBatch]
    @Published var selectedReadingBatchID: UUID?
    @Published var openBatchIDs:Set<UUID> = []
    private var forwarding: AnyCancellable?

    init(storage: URL? = nil, readingDefaults: UserDefaults? = nil) {
        let folder = storage ?? ProcessInfo.processInfo.environment["KONGFOLIO_STORAGE"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
        self.storage = folder
        self.library = BookLibrary(storage: folder)
        self.readingDefaults = readingDefaults ?? (AppEnvironment.isTestRun ? UserDefaults(suiteName: "KongFolio.ReadingTests." + UUID().uuidString)! : .standard)
        self.homePinnedFolders = HomePinnedFolder.load(self.readingDefaults)
        self.readingBatches = ReadingOpenBatch.loadHistory(self.readingDefaults)
        self.readingMode = self.readingDefaults.object(forKey:Self.readingModeKey) as? Bool ?? !AppEnvironment.isTestRun
        self.documentTasks = DocumentTaskQueue(storage: folder)
        self.board = Board(storage: folder)
        self.batchQueue = BatchQueue(storage: AppEnvironment.isTestRun && storage == nil ? nil : folder)
        self.folderSearch = FolderSearchModel(storage:folder)
        documentTasks.didFinishPersistent = { [weak self] result in
            guard result.file?.pathExtension == "json", let self else { return }
            for workspace in self.tabs.compactMap(\.workspace) { workspace.loadTableDrafts() }
        }
        library.didRelink = { [weak self] old, url in
            do { try self?.research.relink(from: old, to: url); self?.journal.relink(old:old,to:url) } catch { self?.present(error) }
        }
        connectBoardToDocuments()
    }

    var activeTab: OpenTab? { tabs.first { $0.id == selectedID } }
    var activeWorkspace: Workspace? { activeTab?.workspace }

    /// Shows `text` in the status bar of the open document (nil clears it everywhere, so no stale hint stays behind a tab switch).
    func setPathHint(_ text: String?) {
        for workspace in tabs.compactMap(\.workspace) where workspace.pathHint != nil { workspace.pathHint = nil }
        if let text { activeWorkspace?.pathHint = text }
    }

    /// With two documents side by side, the one the reader last clicked in; nil or the active tab otherwise.
    @Published private(set) var focusedID: UUID?

    /// The quick tab switcher (⌘P) is open.
    @Published var showSwitcher = false
    @Published var showCommandPalette = false

    /// Tabs whose names match `query`, best match first; with nothing typed, the most recently used first.
    func switcherResults(for query: String) -> [OpenTab] {
        let ordered = tabs.enumerated().sorted { lhs, rhs in
            lhs.element.lastUsed != rhs.element.lastUsed ? lhs.element.lastUsed > rhs.element.lastUsed : lhs.offset < rhs.offset
        }.map(\.element)
        return TabSearch.rank(ordered.map(\.switcherTitle), query: query).map { ordered[$0] }
    }

    /// The document that marking, excerpting and undo commands act on: the clicked pane when reading side by side.
    var commandWorkspace: Workspace? {
        guard let active = activeWorkspace else { return nil }
        if let partner = active.splitPartner, partner.id == focusedID { return partner }
        return active
    }

    func focus(_ workspace: Workspace) {
        if focusedID != workspace.id {
            focusedID = workspace.id
            if pdfSearchWorkspaceID != nil { pdfSearchWorkspaceID = workspace.id }
        }
    }
    var activeNote: MarkdownNote? { activeTab?.note }
    var canSave: Bool {
        if let workspace = activeWorkspace { return workspace.count > 0 && !workspace.busy }
        return activeNote != nil
    }
    var canCloseActive: Bool {
        if let workspace = activeWorkspace { return workspace.count > 0 && !workspace.busy }
        return activeNote != nil
    }
    static func textUndoResponder(in window:NSWindow?) -> NSTextView? { guard let view = window?.firstResponder as? NSTextView,view.isEditable,!view.hasMarkedText() else { return nil };return view }
    var researchTextResponder:NSTextView? { Self.textUndoResponder(in:NSApp?.keyWindow) }
    var canUndo: Bool { if let text = researchTextResponder { return text.undoManager?.canUndo ?? false }; return commandWorkspace.map { $0.canUndo && !$0.busy && !$0.readingLocked } ?? (activeNote != nil) }
    var canRedo: Bool { if let text = researchTextResponder { return text.undoManager?.canRedo ?? false }; return commandWorkspace.map { $0.canRedo && !$0.busy && !$0.readingLocked } ?? (activeNote != nil) }

    // MARK: Session

    private var sessionURL: URL { storage.appendingPathComponent("Session.json") }

    /// Restores the tabs of the last session. Tabs with unsaved changes come back from their recovery copies; unchanged ones
    /// are only remembered by path and are read when selected, so many open files cost nothing at launch.
    func bootstrap() {
        guard tabs.isEmpty else { return }
        if let value = readingDefaults.object(forKey: "KongFolio.maximumLoadedTabs") as? Int { maxLoadedTabs = min(24,max(1,value)) }
        if let value = readingDefaults.object(forKey: "KongFolio.memoryBudgetMB") as? Int { memoryBudgetMB = min(4096,max(128,value)) }
        if !AppEnvironment.isTestRun {
            diagnosticMonitor = ResponsivenessMonitor(storage: storage)
            let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            monitor.setEventHandler { [weak self] in self?.trimLoadedTabs(pressure: true) }
            monitor.resume(); memoryMonitor = monitor
        }
        if !AppEnvironment.isTestRun {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now()+2,repeating:5)
            timer.setEventHandler { [weak self] in self?.sampleRuntimeMemory() }; timer.resume(); runtimeTimer = timer
        }
        let hadStartupMarker = FileManager.default.fileExists(atPath:StartupProtection(storage:storage).url.path)
        let startup = startupSafetyEnabled ? ((try? StartupProtection(storage:storage).begin()) ?? StartupProtection.State(clean:false,reviewRequired:true)) : StartupProtection.State()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        func recoveryExists(_ slot: String) -> Bool {
            slot.isEmpty ? (names.contains("Recovery.kfrecovery") || names.contains("Recovery.kongfolio")) : names.contains("Recovery-\(slot).kfrecovery")
        }
        let session = (try? Data(contentsOf: sessionURL)).flatMap(Session.decode) ?? Session()
        var entries = session.entries
        // A recovery copy that the session file does not mention comes from a crash; bring it back too.
        for name in names.sorted() where name.hasPrefix("Recovery-") && name.hasSuffix(".kfrecovery") {
            let slot = String(name.dropFirst("Recovery-".count).dropLast(".kfrecovery".count))
            if !entries.contains(where: { $0.slot == slot }) { entries.append(SessionEntry(slot: slot, kind: .recovery)) }
        }
        if recoveryExists(""), !entries.contains(where: { $0.slot.isEmpty }) { entries.insert(SessionEntry(slot: "", kind: .recovery), at: 0) }
        entries.removeAll { startup.excludedSlots.contains($0.slot) }
        let needsStartupReview = startup.reviewRequired || (!hadStartupMarker && entries.contains { recoveryExists($0.slot) })
        if startupSafetyEnabled && needsStartupReview && !entries.isEmpty {
            try? StartupProtection(storage:storage).requireReview()
            startupEntries = entries; startupSuspects = startup.interrupted; pendingStartupSelected = session.selected
            addWorkspace(); showStartupReview = true; return
        }
        let policy = ReadingLaunchPolicy(rawValue:readingDefaults.string(forKey:ReadingLaunchPolicy.key) ?? "") ?? .all
        let permitted = policy.entries(entries,selected:session.selected)
        startupEntries = entries.filter { !permitted.contains($0) }
        var selectedTab: UUID?
        for entry in permitted {
            let workspace = Workspace(storage: storage, slot: entry.slot, readingDefaults: readingDefaults)
            workspace.store = self
            workspace.readingBatchEntryID = entry.readingBatchEntryID
            // Unsaved changes win: a recovery copy exists, so the tab was not clean when the app ended.
            if entry.kind == .recovery || recoveryExists(entry.slot) {
                guard recoveryExists(entry.slot) else { continue }
            } else if let path = entry.path, FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                workspace.needsLoad = true
                if entry.kind == .project { workspace.projectURL = url } else { workspace.sourceURL = url }
                workspace.pendingView = entry.position
                workspace.pendingReadingLayout = entry.layout ?? ReadingProgress.load(path: path, defaults: readingDefaults).layout
                workspace.needsLoad = true
            } else {
                continue
            }
            workspace.bootstrap()
            tabs.append(.document(workspace))
            if entry.slot == session.selected { selectedTab = workspace.id }
        }
        for note in MarkdownNote.restoreBackups(storage: storage) { note.store = self; tabs.append(.note(note)) }
        if let backup = Board.restoreBackup(storage: storage) {
            board.load(backup.file, from: nil)
            board.dirty = true
            board.status = backup.status
            backup.removeBackup()
            try? board.writeBackup()
        }
        if tabs.isEmpty { addWorkspace() }
        if let target = selectedTab ?? tabs.first?.id { select(target) }
    }

    func scheduleSessionSave() {
        guard startupSafetyEnabled else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(350)) } catch { return }
            self?.saveSession()
        }
    }

    func saveSession() {
        var entries = tabs.compactMap { $0.workspace?.sessionEntry }
        entries += startupEntries.filter { pending in !entries.contains { $0.slot == pending.slot } }
        let selected = activeWorkspace.flatMap { workspace in
            entries.contains(where:{ $0.slot == workspace.slot }) ? workspace.slot : nil
        } ?? pendingStartupSelected
        let session = Session(entries: entries, selected: selected)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
    }

    // MARK: Tabs

    private func freshSlot() -> String {
        (tabs.contains { $0.workspace?.slot == "" } || startupEntries.contains { $0.slot == "" } || (startupSafetyEnabled && StartupProtection(storage:storage).read().excludedSlots.contains(""))) ? String(UUID().uuidString.prefix(8)).lowercased() : ""
    }

    private func makeWorkspace(slot:String,bootstrapNow:Bool = true) -> Workspace {
        let workspace = Workspace(storage:storage,slot:slot,readingDefaults:readingDefaults)
        workspace.store = self
        if bootstrapNow { workspace.bootstrap(restoreRecovery:false) }
        return workspace
    }

    @discardableResult func addWorkspace(selectImmediately:Bool = true) -> Workspace {
        let workspace = makeWorkspace(slot:freshSlot())
        tabs.append(.document(workspace))
        if selectImmediately { select(workspace.id) }
        return workspace
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if selectedID != id, let previous = activeWorkspace {
            previous.saveReadingRecord()
        }
        selectedID = id
        trackBatchSelection(tab.workspace)
        focusedID = id
        if pdfSearchWorkspaceID != nil { pdfSearchWorkspaceID = id }
        tab.workspace?.bootstrap(restoreRecovery:false)
        tab.workspace?.refreshSignatureLibrary()
        forwarding = tab.changes.sink { [weak self] _ in self?.objectWillChange.send() }
        recordActivity("切换标签页")
        tab.workspace?.lastActive = Date()
        tab.note?.lastActive = Date()
        tab.workspace?.ensureLoaded()
        trimLoadedTabs()
        scheduleSessionSave()
    }

    // MARK: Side by side

    /// Documents that can be shown beside the active one.
    var splitCandidates: [Workspace] {
        tabs.compactMap(\.workspace).filter { $0.id != selectedID && ($0.count > 0 || $0.needsLoad) }
    }

    /// Shows another open document next to the active one, for reading the two against each other.
    func openSplit(with id: UUID) {
        guard let active = activeWorkspace, let partner = tabs.compactMap(\.workspace).first(where: { $0.id == id }), partner.id != active.id else { return }
        partner.lastActive = Date()
        partner.ensureLoaded()
        active.splitPartner = partner
        active.splitSync = false
        active.splitOffset = partner.selection - active.selection
    }

    func closeSplit() { activeWorkspace?.splitPartner = nil; focusedID = selectedID }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    private func step(_ offset: Int) {
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    // MARK: Memory

    /// How many documents stay in memory. Beyond this, the ones used longest ago are released if nothing would be lost
    /// (no unsaved changes, no undo history, not busy); they are read again when selected.
    @Published var maxLoadedTabs = 8 { didSet { readingDefaults.set(maxLoadedTabs, forKey: "KongFolio.maximumLoadedTabs"); trimLoadedTabs() } }
    @Published var memoryBudgetMB = 768 { didSet { readingDefaults.set(memoryBudgetMB, forKey: "KongFolio.memoryBudgetMB"); trimLoadedTabs() } }
    var memoryMonitor: DispatchSourceMemoryPressure?
    var diagnosticMonitor: ResponsivenessMonitor?

    func loadedTabsChanged() { trimLoadedTabs() }

    private func trimLoadedTabs(pressure: Bool = false) {
        let loaded = tabs.compactMap(\.workspace).filter { $0.count > 0 }
        let pressure = pressure || constrainedMemory
        for w in loaded { w.thumbnails.constrain(pressure) }
        if pressure { for w in loaded where w.id != selectedID { w.thumbnails.clear() } }
        var excess = loaded.count - (pressure ? 1 : maxLoadedTabs) - loaded.filter { $0.unloadWorker != nil }.count
        var bytes = loaded.reduce(0) { $0 + $1.estimatedResidentBytes }
        let budget = max(64, memoryBudgetMB) * 1024 * 1024
        let partners = Set(tabs.compactMap(\.workspace).compactMap { $0.splitPartner?.id })
        for workspace in loaded.filter({ $0.id != selectedID && $0.id != stagedShelfTab && !partners.contains($0.id) && $0.canUnload }).sorted(by: { $0.lastActive < $1.lastActive }) {
            guard excess > 0 || bytes > budget else { break }
            bytes -= workspace.estimatedResidentBytes; workspace.unload(); excess -= 1
        }
    }

    /// Opens files in the current tab when it is empty, otherwise in a new tab.
    func openInNewTab(_ urls: [URL]) {
        if urls.contains(where: ReadingShortcut.handles) { openEach(urls); return }
        if urls.count == 1, let url = urls.first, TextImport.handles(url) { openNote(url); return }
        let target: Workspace
        if let current = activeWorkspace, current.count == 0, !current.needsLoad, !current.busy { target = current } else { target = addWorkspace() }
        select(target.id)
        target.load(urls)
    }

    /// Opens every file in its own tab. The tabs appear at once with their file names; the first one is read and brought
    /// to the front, the others are read when selected, so opening dozens of files is instant and uses no extra memory.
    func openEach(_ urls: [URL], startBatch:Bool = true) {
        if startBatch { startReadingBatch(urls) }
        ReadingProgress.setHistoryRemoved(Set(urls.filter(\.isFileURL).map(\.path)),removed:false,defaults:readingDefaults)
        var first: UUID?
        var batch = Set<UUID>()
        var pendingTabs:[OpenTab] = []
        func commitPendingTabs() {
            guard !pendingTabs.isEmpty else { return }
            tabs.append(contentsOf:pendingTabs)
            pendingTabs.removeAll()
        }
        var existingDocuments: [String:Workspace] = [:]
        for workspace in tabs.compactMap(\.workspace) {
            if let path = workspace.displayPath { existingDocuments[ReadingBookIdentity.key(path)] = workspace }
        }
        var blank = activeWorkspace.flatMap { workspace in
            workspace.count == 0 && !workspace.needsLoad && !workspace.busy && !workspace.isImporting &&
                workspace.sourceURL == nil && workspace.projectURL == nil ? workspace : nil
        } ?? emptyFileChooserWorkspace
        for url in urls {
            if ReadingShortcut.handles(url) {
                commitPendingTabs()
                do { try openReadingShortcut(url); if first == nil { first = selectedID } } catch { present(error) }
                continue
            }
            if TextImport.handles(url) {
                commitPendingTabs()
                openNote(url)
                if first == nil { first = selectedID }
                continue
            }
            let path = ReadingBookIdentity.key(url.path)
            let entry = readingBatch?.entry(url.path)
            if let existing = existingDocuments[path] {
                batch.insert(existing.id)
                if let entry { existing.readingBatchEntryID = entry.id }
                if existing.count == 0,!existing.busy {
                    existing.error = nil;existing.needsLoad = true
                    if existing.pendingView == nil { existing.pendingView = readingBatchPosition(url.path) }
                }
                if first == nil { first = existing.id }; continue
            }
            let target: Workspace
            if let available = blank { target = available; blank = nil }
            else {
                let slot = pendingTabs.isEmpty ? freshSlot() : String(UUID().uuidString.prefix(8)).lowercased()
                target = makeWorkspace(slot:slot,bootstrapNow:false)
                pendingTabs.append(.document(target))
            }
            target.needsLoad = true
            target.sourceURL = url
            target.readingBatchEntryID = entry?.id
            target.pendingView = readingBatchPosition(url.path)
            existingDocuments[path] = target
            batch.insert(target.id)
            if first == nil { first = target.id }
        }
        commitPendingTabs()
        openBatchIDs = batch
        if let first { select(first) }
    }

    /// An idle blank tab is safe to reuse once the user has selected a document.
    var emptyFileChooserWorkspace:Workspace? {
        tabs.compactMap(\.workspace).first { $0.count == 0 && !$0.needsLoad && !$0.busy && !$0.isImporting && $0.sourceURL == nil && $0.projectURL == nil }
    }
    func open() { open(directory:nil) }

    func open(directory:URL?) {
        guard !DocumentOpenPanel.coordinator.revealExisting() else { return }
        recordActivity("显示文件选择器")
        let panel = DocumentOpenPanel.files(offersFinder:true)
        if let directory { panel.directoryURL = directory }
        DocumentOpenPanel.coordinator.present(panel,presentation:.separate) { [weak self] response,urls in
            guard let self else { return }
            self.finishOpeningDocuments(response,urls:urls)
        }
    }

    func finishOpeningDocuments(_ response:NSApplication.ModalResponse,urls:[URL]) {
        if response == .abort {
            recordActivity("文件选择器未能显示")
            present(FolioError(message:"系统文件选择器未能显示。可重试，或从访达打开文档。"))
        } else if response == .OK, !urls.isEmpty {
            recordActivity("文件选择器已返回文件")
            openEach(urls)
        } else { recordActivity("关闭文件选择器") }
    }

    func browseFilesInFinder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: Notes

    @discardableResult func newNote(format: TextDocumentFormat = .markdown) -> MarkdownNote {
        let note = MarkdownNote(storage: storage, format: format)
        note.focusNewEditor = true
        note.showPreview = false
        note.store = self; tabs.append(.note(note))
        select(note.id)
        return note
    }

    func openNote(_ url: URL) {
        if let existing = tabs.compactMap(\.note).first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            select(existing.id)
            return
        }
        do {
            let note = try MarkdownNote.open(url, storage: storage)
            note.store = self; tabs.append(.note(note))
            select(note.id)
        } catch {
            present(error)
        }
    }

    func editMarkdownFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = TextImport.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openNote)
    }

    func present(_ error: Error) {
        guard !FolioCancellation.matches(error), AppEnvironment.isInteractive else { return }
        NSAlert(error: error).runModal()
    }

    // MARK: Closing

    private var closingTabs = Set<UUID>()
    private var completedCloseSave = Set<UUID>()
    private func finishClosing(_ id: UUID) {
        completedCloseSave.insert(id)
        defer { completedCloseSave.remove(id) }
        close(id)
    }
    /// Finish original-file writes before the existing session/termination checks run.
    func finishPendingSaves() async -> Bool {
        await readingExportBatch.stopAndWait();await readingPackage.stopAndWait();await incrementalExport.stopAndWait();WritingPositions.shared.flush()
        guard ResearchDraftRegistry.shared.flush(storage:storage) else { present(FolioError(message:"研究整理草稿未能保存，请处理后再关闭")); return false }
        await importLegacyReadingRecords()
        do { await journal.waitForMaintenance(); try await journal.flush();await ReadingMirrorWriter053.shared.drain(); try await library.flushReflections() } catch { present(error); return false }
        for workspace in tabs.compactMap(\.workspace) { await workspace.unloadWorker?.value }
        for workspace in tabs.compactMap(\.workspace) where workspace.count > 0 && (workspace.dirty || workspace.saving || workspace.hasPrivateReadingData) {
            if !(await workspace.finishPendingSave()) { select(workspace.id); return false }
        }
        return true
    }

    func closeActive() { if let id = selectedID { close(id) } }

    /// Closes a tab after confirming unsaved work. The last tab is never removed: it returns to the start screen.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index] {
        case .document(let workspace):
            if workspace.isImporting { workspace.cancelImport() }
            guard !workspace.busy else { workspace.status = "请等待任务完成或点击取消任务"; return }
            if let pending = workspace.unloadWorker {
                guard !closingTabs.contains(id) else { return }
                closingTabs.insert(id)
                Task { await pending.value; closingTabs.remove(id); close(id) }
                return
            }
            if !AppEnvironment.isTestRun, !completedCloseSave.contains(id), workspace.count > 0, workspace.dirty || workspace.saving || workspace.hasPrivateReadingData {
                guard !closingTabs.contains(id) else { return }
                closingTabs.insert(id)
                Task {
                    let saved = await workspace.finishPendingSave()
                    closingTabs.remove(id)
                    guard saved, !workspace.dirty, !workspace.saving else { return }
                    finishClosing(id)
                }
                return
            }
            if workspace.count > 0 {
                let position = workspace.currentViewPosition()
                let entry = readingBatchEntry(for:workspace)
                let isReading = !workspace.browsingReadingReference
                if !workspace.closeDocument() { return }
                if let entry,isReading {
                    updateBatchEntry(entry.id) {
                        $0.position = position
                        if $0.status == .pending { $0.status = .finished }
                    }
                }
            } else { workspace.forgetSource() }
            if tabs.count == 1 { scheduleSessionSave(); return }
        case .note(let note):
            guard note.confirmClose() else { return }
            note.releaseEditorResources()
            if tabs.count == 1 {
                tabs.removeAll()
                addWorkspace()
                return
            }
        }
        tabs.remove(at: index)
        scheduleSessionSave()
        for workspace in tabs.compactMap(\.workspace) where workspace.splitPartner?.id == id { workspace.splitPartner = nil }
        if selectedID == id, !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)].id) }
    }

    /// Called when the window closes or the app quits. Walks through every tab; any cancel stops the quit.
    func prepareToClose() -> Bool {
        folderSearch.cancel()
        if documentTasks.running { documentTasks.pauseAll() }
        if batchQueue.running {
            batchQueue.cancel()
            batchQueue.summary = "正在暂停任务；当前页结束后可再次关闭。未完成项会保留。"
            showTaskCenter = true
            return false
        }
        if board.dirty, board.hasContent {
            if readingMode { do { try board.writeBackup() } catch { present(error); return false } }
            else if !board.confirmClose() { return false }
        }
        for tab in tabs {
            switch tab {
            case .document(let workspace):
                if workspace.dirty || workspace.busy { select(tab.id) }
                if !workspace.prepareToClose() { return false }
            case .note(let note):
                if note.dirty { select(tab.id) }
                if !note.confirmClose() { return false }
            }
        }
        saveSession()
        return true
    }

    // MARK: Commands on the active tab

    func saveActive(asNew: Bool = false) {
        if let workspace = activeWorkspace {
            if asNew { workspace.saveProject(asNew: true) } else if workspace.historySource != nil { Task { _ = await workspace.saveInBackground(automatic: false, includePrivateData: true) } } else { workspace.saveDirectly() }
        }
        else { activeNote?.save(asNew: asNew) }
    }

    func exportActive() {
        if let workspace = activeWorkspace { workspace.exportPDF() }
        else { activeNote?.exportPDF() }
    }

    func undoActive() {
        if let text = researchTextResponder { text.undoManager?.undo(); return }
        if let workspace = commandWorkspace { workspace.undo() }
        else { activeNote?.textView?.undoManager?.undo() }
    }

    func redoActive() {
        if let text = researchTextResponder { text.undoManager?.redo(); return }
        if let workspace = commandWorkspace { workspace.redo() }
        else { activeNote?.textView?.undoManager?.redo() }
    }
}

extension OpenTab {
    /// The name the tab shows.
    var switcherTitle: String {
        switch self {
        case .document(let workspace):
            return workspace.count == 0 && workspace.sourceURL == nil && workspace.projectURL == nil ? "首页" : workspace.displayName
        case .note(let note): return note.title
        }
    }

    /// The folder of the file, or a short description.
    var switcherDetail: String? {
        switch self {
        case .document(let workspace): return workspace.displayPath.map { ($0 as NSString).deletingLastPathComponent }
        case .note(let note): return note.fileURL.map { $0.deletingLastPathComponent().path } ?? "Markdown 笔记（未保存）"
        }
    }

    var switcherIcon: String {
        switch self {
        case .document: return "doc.richtext"
        case .note: return "square.and.pencil"
        }
    }

    var lastUsed: Date {
        switch self {
        case .document(let workspace): return workspace.lastActive
        case .note(let note): return note.lastActive
        }
    }
}

extension WorkspaceStore {
    @discardableResult func newPDF() -> Workspace {
        let workspace = addWorkspace()
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: TextImport.pageSize), for: .mediaBox)
        let document = PDFDocument(); document.insert(page, at: 0)
        workspace.document = document
        workspace.title = "未命名 PDF"
        workspace.edited(reset: true)
        workspace.status = "已新建 A4 PDF，可添加文字、图片和标注"
        return workspace
    }
    func exportWordActive() {
        if let note = activeNote { note.exportWord() }
        else { activeWorkspace?.showWordExport = true }
    }
}

extension WorkspaceStore {
    func tabsForStartup(_ workspace: Workspace) {
        tabs.append(.document(workspace)); select(workspace.id)
    }
}
