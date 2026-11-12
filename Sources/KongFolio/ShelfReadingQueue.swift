import Foundation

extension WorkspaceStore {
    func continueShelfQueue() {
        guard let next = library.nextShelfQueueBook() else {
            present(FolioError(message:"待读队列没有下一份文献"))
            return
        }
        Task {
            do { try await openShelfQueueBook(next) }
            catch where FolioCancellation.matches(error) {}
            catch { present(error) }
        }
    }

    func openShelfQueueBook(_ book:LibraryBook) async throws {
        guard !shelfQueueOpening else { return }
        shelfQueueOpening = true
        defer { shelfQueueOpening = false }
        let shortcut = library.resolve(ReadingShortcut(path:book.path,title:book.title,
                                                       position:ViewPosition(selection:0),bookmark:book.bookmark))
        let url = try await Task.detached(priority:.userInitiated) { try shortcut.resolvedURL() }.value
        guard !TextImport.handles(url) else { throw FolioError(message:"待读队列用于 PDF 和 KongFolio 项目") }
        let previous = shelfQueueTab
        let alreadyOpen = tabs.compactMap(\.workspace).first{$0.matches(path:url.path) && $0.count > 0}
        let workspace = try openReadingShortcut(shortcut,resolvedFile:url)
        showReadingHistory = false
        while workspace.count == 0, workspace.isImporting || workspace.busy {
            try await Task.sleep(for:.milliseconds(150))
        }
        guard workspace.count > 0 else { throw FolioError(message:workspace.error ?? "未能打开队列中的文献") }
        try library.markShelfQueuePosition(book.id)
        if let previous, previous != workspace.id { close(previous) }
        shelfQueueTab = alreadyOpen == nil || previous == workspace.id ? workspace.id : nil
        shelfQueueReadingTab = workspace.id
    }
}
