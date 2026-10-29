import Foundation

extension ResearchBackup {
    func selecting(_ paths: Set<String>, includeShared: Bool) throws -> Self {
        let selected = Set(paths.map(ReadingProgress.canonicalPath))
        func keep(_ path: String) -> Bool { selected.contains(ReadingProgress.canonicalPath(path)) }
        var value = self
        value.catalog.books = catalog.books.filter { keep($0.path) }
        guard !value.catalog.books.isEmpty || includeShared else { throw FolioError(message:"请至少选择一本书籍") }
        value.catalog.pendingBooks = includeShared ? catalog.pendingBooks : catalog.pendingBooks?.filter { keep($0.path) }
        value.catalog.shortcuts = catalog.shortcuts.filter { keep($0.shortcut.path) }
        value.catalog.relocated = catalog.relocated.filter { keep($0.key) || keep($0.value) }
        value.research.labels = research.labels.filter { keep($0.key) }
        value.research.identities = research.identities?.filter { keep($0.key) }
        value.research.periodicals = research.periodicals.filter { keep($0.key) }
        value.research.bindings = research.bindings?.filter { keep($0.key) }
        value.research.annotations = research.annotations.filter { keep($0.path) }
        value.research.editions = research.editions.filter { keep($0.leftPath) && keep($0.rightPath) }
        value.research.topics = research.topics?.compactMap { topic in var topic = topic; topic.items.removeAll { !keep($0.annotation.path) }; return topic.items.isEmpty ? nil : topic }
        value.research.groups = research.groups.compactMap { group in
            let indexes = group.books.indices.filter { keep(group.books[$0].path) }
            guard !indexes.isEmpty else { return nil }
            var next = group
            next.books = indexes.map { index in var book = group.books[index]; book.partner = book.partner.flatMap { indexes.firstIndex(of:$0) }; return book }
            next.selected = indexes.firstIndex(of:group.selected) ?? 0; return next
        }
        let categories = Set(value.catalog.books.map(\.category))
        value.research.dictionary = research.dictionary.filter { $0.scope == "全局" || categories.contains($0.scope) || keep($0.scope) }
        let bookPaths = Set(catalog.books.map { ReadingProgress.canonicalPath($0.path) })
        let journal = try companions.first(where:{$0.path == "ReadingJournal/catalog.json"}).map { try JSONDecoder().decode(ReadingJournalState.self,from:$0.bytes) }
        let journalPaths = Set(((journal?.records ?? [])+(journal?.essays.flatMap{$0.blocks.compactMap(\.record)} ?? [])).flatMap{$0.citations.map{ReadingProgress.canonicalPath($0.source.path)}})
        value.originals = originals.filter { key,_ in let path = ReadingProgress.canonicalPath(key); return (!(bookPaths.contains(path) || journalPaths.contains(path))) || keep(key) || (includeShared && journalPaths.contains(path)) }
        value.originalDigests = originalDigests.filter { value.originals[$0.key] != nil }
        value.aliases = aliases?.filter { value.originals[$0.value] != nil }
        value.progress = progress.filter { keep($0.key) }
        let identities = paths.flatMap { [$0,ReadingProgress.canonicalPath($0),URL(fileURLWithPath:$0).standardizedFileURL.path] } + (aliases ?? [:]).keys.filter(keep)
        let hashes = Set(identities.map { OCRPageCache.digest(Data($0.utf8)) })
        let perBook: Set<String> = ["ReadingDocuments","SignatureEdits","AcademicDrafts","WordDrafts","TableDrafts","ReadingRulers","History","TextHistory"]
        value.companions = companions.filter { asset in
            let parts = asset.path.split(separator:"/").map(String.init)
            if perBook.contains(parts[0]), parts.count > 1 { return hashes.contains(URL(fileURLWithPath:parts[1]).deletingPathExtension().lastPathComponent) || hashes.contains(parts[1]) }
            return parts[0] == "NoteAssets" || includeShared
        }
        if let asset = companions.first(where:{$0.path == "ReadingJournal/catalog.json"}) {
            var journal = try JSONDecoder().decode(ReadingJournalState.self,from:asset.bytes)
            if !includeShared {
                journal.records = journal.records.filter { $0.citations.contains{keep($0.source.path)} }
                journal.essays = journal.essays.filter { essay in let refs = essay.blocks.compactMap(\.record).flatMap(\.citations); return !refs.isEmpty && refs.allSatisfy{keep($0.source.path)} }
            }
            let ids = Set(journal.records.map(\.id)); journal.lastNotes = journal.lastNotes.filter{ids.contains($0.value)}
            if !journal.essays.contains(where:{$0.id == journal.currentEssay}) { journal.currentEssay = nil }
            let images = Set((journal.records+journal.essays.flatMap{$0.blocks.compactMap(\.record)}).compactMap(\.imageAsset))
            value.companions.removeAll{$0.path.hasPrefix("ReadingJournal/")}
            let bytes = try JSONEncoder().encode(journal)
            value.companions.append(Asset(path:"ReadingJournal/catalog.json",bytes:bytes,digest:OCRPageCache.digest(bytes)))
            value.companions += companions.filter{$0.path.hasPrefix("ReadingJournal/Assets/") && images.contains(URL(fileURLWithPath:$0.path).lastPathComponent)}
        }
        try value.validate(); return value
    }
}
