import Foundation

struct FolderSearchTerms {
    var required: [String] = []
    var excluded: [String] = []
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    /// Additional terms apply to the same physical page as the primary phrase.
    func accepts(_ text: String, cache: inout [String: String]) -> Bool {
        for term in required where ReadingServices.matches(in: text, query: term, cache: &cache, limit: 1).isEmpty { return false }
        for term in excluded where !ReadingServices.matches(in: text, query: term, cache: &cache, limit: 1).isEmpty { return false }
        return true
    }
}

extension FolderSearchModel {
    var visibleResults: [FolderSearchHit] {
        let pages = pageFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bad page range produces no results and a visible explanation, never a silent fallback to all pages.
        let allowed = pages.isEmpty ? nil : PageSpan.parse(pages, pageCount: files.map(\.pages).max() ?? 0).map(Set.init)
        if !pages.isEmpty && allowed == nil { return [] }
        return results.filter { value in
            (fileFilter.isEmpty || value.relativePath.localizedStandardContains(fileFilter)) && (allowed == nil || allowed!.contains(value.hit.page))
        }
    }
    var pageFilterInvalid: Bool {
        !pageFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && PageSpan.parse(pageFilter, pageCount: files.map(\.pages).max() ?? 0) == nil
    }
    func keepFolder(_ url: URL) {
        folder = url.standardizedFileURL
        savedFolders.removeAll { $0.standardizedFileURL.path == folder?.path }
        savedFolders.insert(folder!, at: 0)
        remember()
    }
    func forgetFolder(_ url: URL) { savedFolders.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }; remember() }
    func excerpt(_ selected: [FolderSearchHit], in store: WorkspaceStore) async -> Bool {
        guard !running, openingID == nil, !selected.isEmpty else { return false }
        openingID = selected[0].id
        defer { openingID = nil; openWorkerForExcerpts = nil }
        var live: [(UUID, String, SourceRef)] = []
        do { live = try selected.filter { $0.tabID != nil || $0.cardID != nil }.map { value in let entry = try store.liveExcerpt(value); return (value.id, entry.0, entry.1) } }
        catch { message = error.localizedDescription; return false }
        let saved = selected.filter { $0.tabID == nil && $0.cardID == nil }
        let job = Task.detached(priority: .userInitiated) { () throws -> [(String, SourceRef)] in
            try FolderSearchService.verifiedExcerpts(saved)
        }
        openWorkerForExcerpts = job
        do {
            let disk = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
            guard !job.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            // Validate the live sources again after the worker finishes, before adding anything.
            for value in selected where value.tabID != nil || value.cardID != nil { _ = try store.liveExcerpt(value) }
            let verified = disk + live.map { ($0.1, $0.2) }
            var added = 0
            for (text, source) in verified {
                if let existing = store.board.existingExcerpt(text: text, source: source) { store.board.focus(existing.id) }
                else { store.board.focus(store.board.addExcerpt(text: text, source: source)); added += 1 }
            }
            if store.activeWorkspace == nil {
                let workspace = store.tabs.compactMap(\.workspace).first ?? store.addWorkspace()
                store.select(workspace.id)
            }
            UserDefaults.standard.set(true, forKey: LayoutKeys.board)
            message = "已摘录 \(added) 处，重复内容已跳过；出处可从卡片返回。"
            store.board.status = message
            return true
        } catch is CancellationError { message = "已取消摘录，工作区未添加内容" }
        catch { message = "摘录失败，工作区未添加内容：" + error.localizedDescription }
        return false
    }
}
