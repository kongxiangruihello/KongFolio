import Foundation

/// Finder/Dock can deliver documents before the SwiftUI window has attached its workspace.
@MainActor final class ExternalDocumentRouter {
    private weak var store: WorkspaceStore?
    private var pending: [URL] = []
    private var recent: [String: Date] = [:]
    private(set) var errors: [String] = []
    func attach(_ store: WorkspaceStore) {
        self.store = store
        guard !pending.isEmpty else { return }
        let queued = pending; pending.removeAll(); store.bootstrap(); receive(queued)
    }
    func receive(_ urls: [URL], now: Date = Date()) {
        guard let store else { pending.append(contentsOf: urls); return }
        store.bootstrap()
        recent = recent.filter { now.timeIntervalSince($0.value) < 1 }
        for url in urls {
            let key = url.absoluteString
            if let previous = recent[key], now.timeIntervalSince(previous) < 0.5 { continue }
            recent[key] = now
            do {
                if ReadingShortcut.handles(url) { try store.openReadingShortcut(url) }
                else if let source = SourceLink.source(url) {
                    store.reveal(try SourceLink.resolved(source, baseURL: store.activeNote?.fileURL?.deletingLastPathComponent()), beside: false)
                } else if url.isFileURL {
                    if TextImport.handles(url) { store.openNote(url) } else { store.openInNewTab([url]) }
                } else { throw FolioError(message: "无法识别这个 KongFolio 阅读链接") }
            } catch {
                errors.append(error.localizedDescription); errors = Array(errors.suffix(20)); store.present(error)
            }
        }
    }
}
