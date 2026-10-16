import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// One tab: a PDF/image document workspace or a Markdown note being edited.
@MainActor enum OpenTab: Identifiable {
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
    private var forwarding: AnyCancellable?

    init(storage: URL? = nil) {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
    }

    var activeTab: OpenTab? { tabs.first { $0.id == selectedID } }
    var activeWorkspace: Workspace? { activeTab?.workspace }
    var activeNote: MarkdownNote? { activeTab?.note }
    var canSave: Bool {
        if let workspace = activeWorkspace { return workspace.count > 0 && !workspace.busy }
        return activeNote != nil
    }
    var canCloseActive: Bool {
        if let workspace = activeWorkspace { return workspace.count > 0 && !workspace.busy }
        return activeNote != nil
    }
    var canUndo: Bool { activeWorkspace.map { $0.canUndo && !$0.busy } ?? (activeNote != nil) }
    var canRedo: Bool { activeWorkspace.map { $0.canRedo && !$0.busy } ?? (activeNote != nil) }

    // MARK: Session

    private var sessionURL: URL { storage.appendingPathComponent("Session.json") }

    /// Restores the tabs of the last session: documents from their recovery copies, notes from their unsaved text.
    func bootstrap() {
        guard tabs.isEmpty else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        func recoveryExists(_ slot: String) -> Bool {
            slot.isEmpty ? (names.contains("Recovery.kfrecovery") || names.contains("Recovery.kongfolio")) : names.contains("Recovery-\(slot).kfrecovery")
        }
        var slots = ((try? JSONDecoder().decode([String].self, from: Data(contentsOf: sessionURL))) ?? []).filter(recoveryExists)
        for name in names.sorted() where name.hasPrefix("Recovery-") && name.hasSuffix(".kfrecovery") {
            let slot = String(name.dropFirst("Recovery-".count).dropLast(".kfrecovery".count))
            if !slots.contains(slot) { slots.append(slot) }
        }
        if recoveryExists(""), !slots.contains("") { slots.insert("", at: 0) }
        for slot in slots {
            let workspace = Workspace(storage: storage, slot: slot)
            workspace.store = self
            workspace.bootstrap()
            tabs.append(.document(workspace))
        }
        for note in MarkdownNote.restoreBackups(storage: storage) { tabs.append(.note(note)) }
        if tabs.isEmpty { addWorkspace() }
        if let first = tabs.first { select(first.id) }
    }

    func saveSession() {
        let slots = tabs.compactMap(\.workspace).filter { $0.count > 0 }.map(\.slot)
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? JSONEncoder().encode(slots).write(to: sessionURL, options: .atomic)
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
        forwarding = tab.changes.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Opens files in the current tab when it is empty, otherwise in a new tab.
    func openInNewTab(_ urls: [URL], scanAfter: Bool = false) {
        let target: Workspace
        if let current = activeWorkspace, current.count == 0, !current.busy { target = current } else { target = addWorkspace() }
        select(target.id)
        target.load(urls, scanAfter: scanAfter)
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

    @discardableResult func newNote() -> MarkdownNote {
        let note = MarkdownNote(storage: storage)
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

    private func present(_ error: Error) {
        guard NSApp != nil else { return }
        NSAlert(error: error).runModal()
    }

    // MARK: Closing

    func closeActive() { if let id = selectedID { close(id) } }

    /// Closes a tab after confirming unsaved work. The last tab is never removed: it returns to the start screen.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index] {
        case .document(let workspace):
            if workspace.count > 0, !workspace.closeDocument() { return }
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
        if selectedID == id, !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)].id) }
    }

    /// Called when the window closes or the app quits. Walks through every tab; any cancel stops the quit.
    func prepareToClose() -> Bool {
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
        if let workspace = activeWorkspace { workspace.saveProject(asNew: asNew) }
        else { activeNote?.save(asNew: asNew) }
    }

    func exportActive() {
        if let workspace = activeWorkspace { workspace.exportPDF() }
        else { activeNote?.exportPDF() }
    }

    func undoActive() {
        if let workspace = activeWorkspace { workspace.undo() }
        else { activeNote?.textView?.undoManager?.undo() }
    }

    func redoActive() {
        if let workspace = activeWorkspace { workspace.redo() }
        else { activeNote?.textView?.undoManager?.redo() }
    }
}
