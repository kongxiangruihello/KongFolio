import AppKit
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
    let storage: URL
    /// The workspace shared by every tab: excerpts from any open document gather here.
    let board: Board
    let batchQueue: BatchQueue
    @Published var showTaskCenter = false
    private var forwarding: AnyCancellable?

    init(storage: URL? = nil) {
        let folder = storage ?? ProcessInfo.processInfo.environment["KONGFOLIO_STORAGE"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
        self.storage = folder
        self.board = Board(storage: folder)
        self.batchQueue = BatchQueue(storage: AppEnvironment.isTestRun && storage == nil ? nil : folder)
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
        if focusedID != workspace.id { focusedID = workspace.id }
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
    var canUndo: Bool { commandWorkspace.map { $0.canUndo && !$0.busy } ?? (activeNote != nil) }
    var canRedo: Bool { commandWorkspace.map { $0.canRedo && !$0.busy } ?? (activeNote != nil) }

    // MARK: Session

    private var sessionURL: URL { storage.appendingPathComponent("Session.json") }

    /// Restores the tabs of the last session. Tabs with unsaved changes come back from their recovery copies; unchanged ones
    /// are only remembered by path and are read when selected, so many open files cost nothing at launch.
    func bootstrap() {
        guard tabs.isEmpty else { return }
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
        var selectedTab: UUID?
        for entry in entries {
            let workspace = Workspace(storage: storage, slot: entry.slot)
            workspace.store = self
            // Unsaved changes win: a recovery copy exists, so the tab was not clean when the app ended.
            if entry.kind == .recovery || recoveryExists(entry.slot) {
                guard recoveryExists(entry.slot) else { continue }
            } else if let path = entry.path, FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                if entry.kind == .project { workspace.projectURL = url } else { workspace.sourceURL = url }
                workspace.pendingView = entry.position
                workspace.needsLoad = true
            } else {
                continue
            }
            workspace.bootstrap()
            tabs.append(.document(workspace))
            if entry.slot == session.selected { selectedTab = workspace.id }
        }
        for note in MarkdownNote.restoreBackups(storage: storage) { tabs.append(.note(note)) }
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

    func saveSession() {
        let entries = tabs.compactMap { $0.workspace?.sessionEntry }
        let session = Session(entries: entries, selected: activeWorkspace?.slot)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
    }

    // MARK: Tabs

    private func freshSlot() -> String {
        tabs.contains { $0.workspace?.slot == "" } ? String(UUID().uuidString.prefix(8)).lowercased() : ""
    }

    @discardableResult func addWorkspace() -> Workspace {
        let workspace = Workspace(storage: storage, slot: freshSlot())
        workspace.store = self
        workspace.bootstrap()
        tabs.append(.document(workspace))
        select(workspace.id)
        return workspace
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedID = id
        focusedID = id
        forwarding = tab.changes.sink { [weak self] _ in self?.objectWillChange.send() }
        tab.workspace?.lastActive = Date()
        tab.note?.lastActive = Date()
        tab.workspace?.ensureLoaded()
        trimLoadedTabs()
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
    var maxLoadedTabs = 8

    func loadedTabsChanged() { trimLoadedTabs() }

    private func trimLoadedTabs() {
        let loaded = tabs.compactMap(\.workspace).filter { $0.count > 0 }
        guard loaded.count > maxLoadedTabs else { return }
        var excess = loaded.count - maxLoadedTabs
        let partners = Set(tabs.compactMap(\.workspace).compactMap { $0.splitPartner?.id })
        for workspace in loaded.filter({ $0.id != selectedID && !partners.contains($0.id) && $0.canUnload }).sorted(by: { $0.lastActive < $1.lastActive }) where excess > 0 {
            workspace.unload()
            excess -= 1
        }
    }

    /// Opens files in the current tab when it is empty, otherwise in a new tab.
    func openInNewTab(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first, TextImport.handles(url) { openNote(url); return }
        let target: Workspace
        if let current = activeWorkspace, current.count == 0, !current.needsLoad, !current.busy { target = current } else { target = addWorkspace() }
        select(target.id)
        target.load(urls)
    }

    /// Opens every file in its own tab. The tabs appear at once with their file names; the first one is read and brought
    /// to the front, the others are read when selected, so opening dozens of files is instant and uses no extra memory.
    func openEach(_ urls: [URL]) {
        var first: UUID?
        for url in urls {
            if TextImport.handles(url) {
                openNote(url)
                if first == nil { first = selectedID }
                continue
            }
            let target: Workspace
            if let current = activeWorkspace, current.count == 0, !current.needsLoad, !current.busy { target = current }
            else { target = addWorkspace() }
            target.sourceURL = url
            target.needsLoad = true
            if first == nil { first = target.id }
        }
        if let first { select(first) }
    }

    /// The "open" command: shows the file panel for an empty document tab, creating one when a note is in front.
    func open() {
        let target: Workspace
        if let current = activeWorkspace { target = current }
        else if let empty = tabs.compactMap(\.workspace).first(where: { $0.count == 0 }) { target = empty }
        else { target = addWorkspace() }
        select(target.id)
        target.open()
    }

    // MARK: Notes

    @discardableResult func newNote(format: TextDocumentFormat = .markdown) -> MarkdownNote {
        let note = MarkdownNote(storage: storage, format: format)
        tabs.append(.note(note))
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
            tabs.append(.note(note))
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
        guard AppEnvironment.isInteractive else { return }
        NSAlert(error: error).runModal()
    }

    // MARK: Closing

    func closeActive() { if let id = selectedID { close(id) } }

    /// Closes a tab after confirming unsaved work. The last tab is never removed: it returns to the start screen.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index] {
        case .document(let workspace):
            guard !workspace.busy else { workspace.status = "请等待任务完成或点击取消任务"; return }
            if workspace.count > 0 { if !workspace.closeDocument() { return } } else { workspace.forgetSource() }
            if tabs.count == 1 { return }
        case .note(let note):
            guard note.confirmClose() else { return }
            if tabs.count == 1 {
                tabs.removeAll()
                addWorkspace()
                return
            }
        }
        tabs.remove(at: index)
        for workspace in tabs.compactMap(\.workspace) where workspace.splitPartner?.id == id { workspace.splitPartner = nil }
        if selectedID == id, !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)].id) }
    }

    /// Called when the window closes or the app quits. Walks through every tab; any cancel stops the quit.
    func prepareToClose() -> Bool {
        if batchQueue.running {
            batchQueue.cancel()
            batchQueue.summary = "正在暂停任务；当前页结束后可再次关闭。未完成项会保留。"
            showTaskCenter = true
            return false
        }
        if board.dirty, board.hasContent, !board.confirmClose() { return false }
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
            if asNew { workspace.saveProject(asNew: true) } else { workspace.saveDirectly() }
        }
        else { activeNote?.save(asNew: asNew) }
    }

    func exportActive() {
        if let workspace = activeWorkspace { workspace.exportPDF() }
        else { activeNote?.exportPDF() }
    }

    func undoActive() {
        if let workspace = commandWorkspace { workspace.undo() }
        else { activeNote?.textView?.undoManager?.undo() }
    }

    func redoActive() {
        if let workspace = commandWorkspace { workspace.redo() }
        else { activeNote?.textView?.undoManager?.redo() }
    }
}

extension OpenTab {
    /// The name the tab shows.
    var switcherTitle: String {
        switch self {
        case .document(let workspace):
            return workspace.count == 0 && workspace.sourceURL == nil && workspace.projectURL == nil ? "新标签页" : workspace.displayName
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
