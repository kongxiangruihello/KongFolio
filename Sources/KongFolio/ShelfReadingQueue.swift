import Foundation
import SwiftUI

struct ShelfQueueProblem: Identifiable {
    let book: LibraryBook
    let message: String
    var id: UUID { book.id }
}

extension WorkspaceStore {
    func continueShelfQueue(resume:Bool = false) {
        let book = resume ? library.resumeShelfQueueBook() : library.nextShelfQueueBook()
        guard let book else { return }
        requestShelfQueueBook(book)
    }

    func requestShelfQueueBook(_ book:LibraryBook) {
        Task {
            do { try await openShelfQueueBook(book) }
            catch where FolioCancellation.matches(error) {}
            catch { shelfQueueProblem = ShelfQueueProblem(book:book,message:error.localizedDescription) }
        }
    }

    func postponeShelfQueueBook(_ book:LibraryBook) {
        do {
            try library.setShelfQueueDeferred(book.id,true)
            continueShelfQueue()
        } catch { present(error) }
    }

    func openShelfQueueBook(_ book:LibraryBook) async throws {
        guard !shelfQueueOpening else { return }
        shelfQueueOpening = true
        defer { stagedShelfTab = nil; shelfQueueOpening = false }
        let previous = shelfQueueTab
        let loaded = try await prepareShelfSequenceBook(book,requireLocal:true)
        do { try library.markShelfQueuePosition(book.id) }
        catch {
            if loaded.created { close(loaded.workspace.id) }
            throw error
        }
        finishShelfSequence(loaded.workspace)
        if let previous, previous != loaded.workspace.id { close(previous) }
        shelfQueueTab = loaded.created || previous == loaded.workspace.id ? loaded.workspace.id : nil
        shelfQueueReadingTab = loaded.workspace.id
    }

    func openShelfIssue(_ book:LibraryBook) {
        guard !shelfQueueOpening else { return }
        shelfQueueOpening = true
        Task {
            defer { stagedShelfTab = nil; shelfQueueOpening = false }
            do {
                let loaded = try await prepareShelfSequenceBook(book,requireLocal:false)
                finishShelfSequence(loaded.workspace)
            } catch where FolioCancellation.matches(error) {}
            catch { present(error) }
        }
    }

    private func prepareShelfSequenceBook(_ book:LibraryBook,requireLocal:Bool) async throws -> (workspace:Workspace,created:Bool) {
        let shortcut = library.resolve(ReadingShortcut(path:book.path,title:book.title,
                                                       position:ViewPosition(selection:0),bookmark:book.bookmark))
        let url = try await Task.detached(priority:.userInitiated) {
            let url = try shortcut.resolvedURL()
            if requireLocal, ShelfFileStatus.read(url) == .cloud {
                throw FolioError(message:"这份文献还在 iCloud。可在访达下载后重试，或先继续阅读下一份。")
            }
            return url
        }.value
        guard !TextImport.handles(url) else { throw FolioError(message:"待读队列用于 PDF 和 KongFolio 项目") }
        let existing = Set(tabs.map(\.id))
        let workspace = try openReadingShortcut(shortcut,resolvedFile:url,selectImmediately:false)
        let created = !existing.contains(workspace.id)
        do {
            while workspace.count == 0, workspace.isImporting || workspace.busy {
                try await Task.sleep(for:.milliseconds(100))
            }
            try Task.checkCancellation()
            guard tabs.contains(where:{$0.id == workspace.id}),workspace.count > 0 else {
                throw FolioError(message:workspace.error ?? "未能打开这份文献")
            }
            return (workspace,created)
        } catch {
            if created { close(workspace.id) }
            throw error
        }
    }

    private func finishShelfSequence(_ workspace:Workspace) {
        select(workspace.id)
        restoreReadingRecord(for:workspace)
        showReadingHistory = false
    }
}

struct ShelfQueueProblemAlert: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    let inShelf: Bool

    func body(content:Content) -> some View {
        let problem = store.shelfQueueProblem
        let visible = Binding(
            get:{ problem != nil && store.showReadingHistory == inShelf },
            set:{
                if !$0, store.showReadingHistory == inShelf, store.shelfQueueProblem?.id == problem?.id {
                    store.shelfQueueProblem = nil
                }
            }
        )
        content.alert("无法打开待读文献",isPresented:visible,presenting:problem) { problem in
            Button("稍后处理并继续") { store.postponeShelfQueueBook(problem.book) }
            Button("关闭",role:.cancel) {}
        } message: { problem in Text(problem.book.title+"\n"+problem.message) }
    }
}
