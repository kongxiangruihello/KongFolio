import Foundation

/// Finder/Dock can deliver documents before the SwiftUI window has attached its workspace.
@MainActor final class ExternalDocumentRouter {
    private weak var store: WorkspaceStore?
    private var pending: [URL] = []
    private var delivery: [URL] = []
    private var deliveryTask: Task<Void,Never>?
    private var recent: [String: Date] = [:]
    private(set) var errors: [String] = []
    func attach(_ store: WorkspaceStore) {
        self.store = store
        guard !pending.isEmpty else { return }
        let queued = pending; pending.removeAll(); store.bootstrap(); receive(queued)
    }
    func enqueue(_ url:URL) {
        delivery.append(url)
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(55))
            guard let self,!Task.isCancelled else { return }
            let urls = delivery
            delivery.removeAll()
            deliveryTask = nil
            receive(urls)
        }
    }

    func receive(_ urls: [URL], now: Date = Date()) {
        guard let store else { pending.append(contentsOf: urls); return }
        store.bootstrap()
        recent = recent.filter { now.timeIntervalSince($0.value) < 1 }
        var documents:[URL] = []
        for url in urls {
            let key = url.absoluteString
            if let previous = recent[key], now.timeIntervalSince(previous) < 0.5 { continue }
            recent[key] = now
            if url.isFileURL && !ReadingShortcut.handles(url) { documents.append(url); continue }
            if !documents.isEmpty { store.openEach(documents); documents.removeAll() }
            do {
                if let item=ReadingRecordLink053.parse(url) {
                    guard store.journal.libraryItem053(item) != nil else { throw FolioError(message:"这条阅读记录不存在或已移除") };store.openReadingItem(item)
                } else if ReadingShortcut.handles(url) { try store.openReadingShortcut(url) }
                else if let source = SourceLink.source(url) {
                    let resolved = try SourceLink.resolved(source,baseURL:store.activeNote?.fileURL?.deletingLastPathComponent())
                    store.openLinkedReadingSource(url,source:resolved)
                } else { throw FolioError(message: "无法识别这个 KongFolio 阅读链接") }
            } catch {
                errors.append(error.localizedDescription); errors = Array(errors.suffix(20)); store.present(error)
            }
        }
        if !documents.isEmpty {
            store.recordActivity("收到访达或外部文件")
            store.openEach(documents)
        }
    }
}
