import AppKit
import PDFKit

extension WorkspaceStore {
    func captureReadingGroup(name: String) throws {
        let workspaces = tabs.compactMap(\.workspace).filter { $0.historySource != nil }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !workspaces.isEmpty else { throw FolioError(message: "请打开书籍并输入阅读组名称") }
        let books = workspaces.map { w in ReadingGroup.Book(path: w.historySource!.path,
            position: w.count > 0 ? w.currentViewPosition() : w.pendingView ?? ViewPosition(selection: 0), layout: w.readingLayout,
            partner: w.splitPartner.flatMap { partner in workspaces.firstIndex { $0.id == partner.id } }, sync: w.splitSync) }
        let group = ReadingGroup(name: name, books: books, selected: workspaces.firstIndex { $0.id == selectedID } ?? 0)
        try research.update { $0.groups.append(group) }
    }
    func restoreReadingGroup(_ group: ReadingGroup) throws {
        guard !group.books.isEmpty else { return }
        var restored: [Workspace] = []
        for book in group.books {
            let shortcut = library.resolve(ReadingShortcut(path: book.path, title: URL(fileURLWithPath: book.path).lastPathComponent, position: book.position))
            let url = try shortcut.resolvedURL()
            let w = tabs.compactMap(\.workspace).first { $0.matches(path: url.path) } ?? addWorkspace()
            guard !w.busy else { throw FolioError(message: "阅读组中的书籍正在处理，请稍后恢复") }
            if w.count > 0 {
                w.selectPage(min(book.position.selection,w.count-1)); w.readingLayout = book.layout
                w.readingPoint = book.position.point; w.readingScale = book.position.scale
                restored.append(w); continue
            }
            w.needsLoad = true
            if url.pathExtension.lowercased() == "kongfolio" { w.projectURL = url } else { w.sourceURL = url }
            w.pendingView = book.position; w.pendingReadingLayout = book.layout
            restored.append(w)
        }
        for (i, book) in group.books.enumerated() {
            if let partner = book.partner, restored.indices.contains(partner), partner != i { restored[i].splitPartner = restored[partner]; restored[i].splitSync = book.sync
                restored[i].splitOffset = group.books[partner].position.selection - book.position.selection
                restored[i].activeEdition = research.state.editions.first { ($0.leftPath == book.path && $0.rightPath == group.books[partner].path) || ($0.rightPath == book.path && $0.leftPath == group.books[partner].path) } }
        }
        let selected = restored[min(max(0,group.selected),restored.count-1)]
        select(selected.id); selected.splitPartner?.ensureLoaded()
    }
    func closeReadingGroup(_ group: ReadingGroup) async -> Bool {
        let paths = Set(group.books.map(\.path))
        let targets = tabs.compactMap(\.workspace).filter { paths.contains($0.displayPath ?? "") }
        for w in targets { if !(await w.finishPendingSave()) { return false } }
        for w in targets { close(w.id) }; return true
    }
    func indexResearchAnnotations() async throws {
        let live = try Dictionary(uniqueKeysWithValues: tabs.compactMap(\.workspace).compactMap { w -> (String, Data)? in
            guard w.count > 0, let path = w.displayPath else { return nil }; return (path, try w.pdfData())
        })
        let books = library.books, previous = research.state.annotations
        let worker = Task.detached { () throws -> ([ResearchAnnotation],[String]) in
            var result: [ResearchAnnotation] = [], unreadable: [String] = []
            for book in books where ["pdf","kongfolio"].contains(URL(fileURLWithPath: book.path).pathExtension.lowercased()) {
                try Task.checkCancellation()
                do { try autoreleasepool {
                let bytes = try live[book.path] ?? (book.path.hasSuffix(".kongfolio") ? ProjectArchive.read(URL(fileURLWithPath: book.path)).pdf : Data(contentsOf: URL(fileURLWithPath: book.path)))
                let doc = try PDFDocument(data: bytes).unwrap("书籍无法读取")
                guard !doc.isLocked, doc.pageCount > 0 else { throw FolioError(message: "书籍需要解锁或没有页面") }
                for note in ReadingServices.notes(doc) {
                    let page = try doc.page(at: note.page).unwrap("标注页已不存在")
                    let mark = page.annotations.indices.contains(note.index) ? page.annotations[note.index] : nil
                    let nativeID = mark?.value(forAnnotationKey: AnnotationIdentity.key) as? String
                    let fallback = "\(note.page):\(note.index):\(note.kind):" + (mark.map { NSStringFromRect($0.bounds) } ?? "")
                    let key = book.path + ":" + (nativeID ?? fallback)
                    let old = previous.first { $0.key == key }
                    let changed = old?.quote != note.quote || old?.comment != note.note || old?.color != (note.colorName ?? "")
                    result.append(ResearchAnnotation(key: key, path: book.path, page: note.page, quote: note.quote, comment: note.note, kind: note.kind, color: note.colorName ?? "", tags: old?.tags ?? [], modified: changed ? Date() : old?.modified ?? Date()))
                }
                } } catch is CancellationError { throw CancellationError() } catch { unreadable.append(book.path) }
            }
            return (result,unreadable)
        }
        let (value,unreadable) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try research.update { state in
            let current = state.annotations
            state.annotations = value.map { item in
                var item = item
                if let latest = current.first(where: { $0.key == item.key }) { item.tags = latest.tags; item.modified = max(item.modified,latest.modified) }
                return item
            } + current.filter { unreadable.contains($0.path) }
        }
        if !unreadable.isEmpty { commandWorkspace?.status = "批注索引已更新；保留 \(unreadable.count) 本未能读取书籍的旧索引，可先重新定位原件" }
    }
}
extension Workspace {
    func copyResearchCitation() throws -> String {
        guard let store, let path = displayPath, let page else { throw FolioError(message: "请先打开并保存原书") }
        let quote = pdfView?.currentSelection?.string ?? selectedAnnotation?.contents ?? ""
        let label = store.research.displayLabel(path: path, page: selection, fallback: ReadingServices.pageLabel(page, index: selection) ?? String(selection + 1))
        let link = try ReadingShortcut(path: path, title: title, mode: .fixed, position: currentViewPosition()).link().absoluteString
        let text = store.research.state.citation.render(author: bibliography.author, title: bibliography.title.isEmpty ? title : bibliography.title,
            periodical: store.research.periodical(path: path)?.citation ?? bibliography.citation, page: label, quote: quote, link: link)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); return text
    }
    func applyResearchEdition(_ edition: EditionCorrespondence) {
        guard let store else { return }
        guard edition.contains(displayPath) else { error = "此对应表不属于当前书籍"; return }
        let left = edition.isLeft(displayPath), other = left ? edition.rightPath : edition.leftPath
        store.openEach([URL(fileURLWithPath: other)])
        guard let partner = store.activeWorkspace else { return }
        let target = edition.mapped(selection, fromLeft: left) ?? 0
        partner.pendingView = ViewPosition(selection: target)
        store.select(id); store.openSplit(with: partner.id)
        splitSync = true
        splitOffset = target - selection
        activeEdition = edition
    }
}
