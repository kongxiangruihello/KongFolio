import Foundation
import PDFKit

struct LibraryBook: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var title: String
    var bookmark: Data?
    var favorite = false
    var category = ""
    var reflection = ""
    var added = Date()
    var topics: [String]? = nil
    var readingStatus: ShelfReadingStatus? = nil
    var shelfAuthor: String? = nil
    var shelfPeriodical: String? = nil
    var shelfYear: String? = nil
    var shelfTags: [String]? = nil
    var shelfDigest: String? = nil
}

struct ManagedReadingShortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var shortcut: ReadingShortcut
    var file: URL?
    var baseline: FileBaseline?
    var created = Date()
}

/// Metadata is separate from originals. A failed or damaged catalog is never silently overwritten.
@MainActor final class BookLibrary: ObservableObject {
    struct Catalog: Codable, Equatable {
        var version = 1
        var books: [LibraryBook] = []
        var shortcuts: [ManagedReadingShortcut] = []
        var relocated: [String: String] = [:]
        var manualOnly: Bool? = true
        var pendingBooks: [LibraryBook]? = nil
        var shelfTopics: [String]? = nil
    }
    private let catalogWriter = DispatchQueue(label: "com.kongfolio.library", qos: .utility)
    private var reflectionTask: Task<Void, Never>?
    private var reflectionPending = false
    private var reflectionWrite: Task<Void, Error>?
    private(set) var reflectionWriteCount = 0
    var didRelink: ((String,URL) -> Void)?
    let storage: URL
    @Published private(set) var catalog = Catalog()
    @Published private(set) var error: String?
    var url: URL { storage.appendingPathComponent("Library/catalog.json") }
    var books: [LibraryBook] { catalog.books }
    var shelfTopics: [String] {
        ShelfBrowse.topics((catalog.shelfTopics ?? []) + books.flatMap(\.shelfTopics)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    var cachedShelfProgress: [String:ReadingProgress] = [:]
    private var shelfUndo: (before:Catalog,after:Catalog)?
    @Published private(set) var shelfUndoName: String?

    var shortcuts: [ManagedReadingShortcut] { catalog.shortcuts }
    init(storage: URL) {
        self.storage = storage
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let value = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw FolioError(message: "书架数据版本不受支持") }
                catalog = value
                if value.manualOnly != true {
                    let backup = url.deletingLastPathComponent().appendingPathComponent("catalog-before-0.41.json")
                    if !FileManager.default.fileExists(atPath:backup.path) { try FileManager.default.copyItem(at:url,to:backup) }
                    var migrated = value
                    migrated.pendingBooks = (value.pendingBooks ?? []) + value.books
                    migrated.books = []; migrated.manualOnly = true
                    try Self.writeCatalog(migrated,to:url); catalog = migrated
                }
            } catch { self.error = "书架未能读取，原记录保留：" + error.localizedDescription }
        }
    }
    private func commit(_ next: Catalog) throws {
        guard error == nil else { throw FolioError(message: error!) }
        let destination = url
        try catalogWriter.sync {
            try Self.writeCatalog(next, to: destination)
        }
        catalog = next
        reflectionTask?.cancel(); reflectionPending = false
    }
    nonisolated private static func writeCatalog(_ value: Catalog, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    func scheduleReflection(_ id: UUID, text: String) throws {
        guard error == nil else { throw FolioError(message: error!) }
        guard let index = catalog.books.firstIndex(where: { $0.id == id }) else { throw FolioError(message: "书籍已不在书架中") }
        guard catalog.books[index].reflection != text else { return }
        catalog.books[index].reflection = text
        reflectionPending = true; reflectionTask?.cancel()
        reflectionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            guard let self else { return }
            do { try await self.flushReflections() }
            catch { self.error = "心得未保存，当前文字仍保留：" + error.localizedDescription }
        }
    }
    func flushReflections() async throws {
        reflectionTask?.cancel(); reflectionTask = nil
        while let reflectionWrite { try await reflectionWrite.value }
        guard reflectionPending else { return }
        let next = catalog, destination = url
        reflectionPending = false
        let write = Task { [self] in
            defer { reflectionWrite = nil }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    catalogWriter.async {
                        do { try Self.writeCatalog(next, to: destination); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                reflectionWriteCount += 1
            } catch { reflectionPending = true; throw error }
        }
        reflectionWrite = write
        try await write.value
        if reflectionPending { try await flushReflections() }
    }

    func importRestoredCatalog(_ value: Catalog) throws {
        var next = catalog
        for var book in value.books where !next.books.contains(where: { $0.path == book.path }) {
            if next.books.contains(where: { $0.id == book.id }) { book.id = UUID() }; next.books.append(book)
        }
        var known = Set(next.books.map(\.id) + (next.pendingBooks ?? []).map(\.id))
        let pending = (value.pendingBooks ?? []).filter { known.insert($0.id).inserted }
        if !pending.isEmpty { if next.pendingBooks == nil { next.pendingBooks = [] }; next.pendingBooks?.append(contentsOf:pending) }
        for var shortcut in value.shortcuts { shortcut.id = UUID(); next.shortcuts.append(shortcut) }
        next.shelfTopics = ShelfBrowse.topics((next.shelfTopics ?? [])+(value.shelfTopics ?? []))
        next.relocated.merge(value.relocated) { current, _ in current }
        try commit(next)
    }
    nonisolated static func supports(_ url: URL) -> Bool { ["pdf", "kongfolio"].contains(url.pathExtension.lowercased()) || TextImport.handles(url) }
    func book(path: String) -> LibraryBook? {
        if let exact = books.first(where: { $0.path == path }) { return exact }
        let identity = ReadingProgress.canonicalPath(path)
        return books.first { ReadingProgress.canonicalPath($0.path) == identity }
    }
    /// Canonicalize each distinct path once, then use a set rather than rescanning the entire shelf for every record.
    nonisolated static func historyIdentities(_ paths: [String], resolve: (String)->String = ReadingProgress.canonicalPath) -> [String:String] {
        var cache: [String:String] = [:]
        for path in paths where cache[path] == nil { cache[path] = resolve(path) }
        return cache
    }
    private func applyHistory(_ history: [ReadingProgress.HistoryItem], identities: [String:String]) throws {
        var next = catalog
        var known = Set(next.books.map { identities[$0.path] ?? $0.path })
        for item in history {
            let identity = identities[item.path] ?? item.path
            guard next.relocated[item.path] == nil, next.relocated[identity] == nil, known.insert(identity).inserted else { continue }
            next.books.append(LibraryBook(path:item.path,title:item.title,bookmark:item.progress.bookmark,added:item.progress.date ?? Date()))
        }
        if next != catalog { try commit(next) }
    }
    func importHistory(defaults: UserDefaults) throws {
        let history = ReadingProgress.history(defaults:defaults)
        let identities = Self.historyIdentities(books.map(\.path) + history.map(\.path))
        try applyHistory(history,identities:identities)
    }
    func refreshHistory(defaults: UserDefaults, importNew: Bool = false) async throws -> [String:ReadingProgress] {
        let snapshot = defaults.dictionaryRepresentation(), paths = books.map(\.path)
        let worker = Task.detached(priority:.utility) { () throws -> ([ReadingProgress.HistoryItem],[String:String]) in
            try Task.checkCancellation()
            let history = ReadingProgress.history(snapshot:snapshot)
            let identities = Self.historyIdentities(paths + history.map(\.path))
            try Task.checkCancellation(); return (history,identities)
        }
        let (history,identities) = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
        try Task.checkCancellation(); if importNew { try applyHistory(history,identities:identities) }
        var byIdentity: [String:ReadingProgress] = [:]
        for item in history { byIdentity[identities[item.path] ?? item.path] = item.progress }
        return books.reduce(into:[:]) { result,book in result[book.path] = byIdentity[identities[book.path] ?? book.path] ?? ReadingProgress() }
    }
    struct PreparedManualBooks {
        var books:[LibraryBook]
        var identities:[String:String]
        var existing:Set<UUID>
    }
    nonisolated static func prepareManualBooks(_ urls:[URL],catalog:Catalog) throws -> PreparedManualBooks {
        var identities = historyIdentities(catalog.books.map(\.path)+(catalog.pendingBooks ?? []).map(\.path)+urls.map(\.path))
        var known = Set(catalog.books.map{identities[$0.path] ?? $0.path})
        var pending:[String:LibraryBook] = [:]
        for book in catalog.pendingBooks ?? [] { pending[identities[book.path] ?? book.path] = book }
        var unavailableDigests = Set<String>()
        var existingBySize: [Int:[URL]]?
        var checkedSizes = Set<Int>()
        var digests = Set<String>()
        var books:[LibraryBook] = []
        for url in urls {
            try Task.checkCancellation()
            guard supports(url),FileManager.default.fileExists(atPath:url.path) else { throw FolioError(message:"请选择可读取的 PDF、项目或文本文件") }
            let path = identities[url.path] ?? ReadingProgress.canonicalPath(url.path); identities[url.path] = path
            guard known.insert(path).inserted else { continue }
            var book = pending[path] ?? LibraryBook(path:path,title:url.deletingPathExtension().lastPathComponent)
            if book.isPDF, let digest = try ShelfFileStatus.digest(url) {
                if existingBySize == nil {
                    var grouped: [Int:[URL]] = [:]
                    for older in catalog.books where older.isPDF {
                        try Task.checkCancellation()
                        let previous = URL(fileURLWithPath:older.path)
                        if ShelfFileStatus.read(previous) == .available,
                           let size = try? previous.resourceValues(forKeys:[.fileSizeKey]).fileSize {
                            grouped[size,default:[]].append(previous)
                        } else if let value = older.shelfDigest { unavailableDigests.insert(value) }
                    }
                    existingBySize = grouped
                }
                if let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,
                   checkedSizes.insert(size).inserted {
                    for previous in existingBySize?[size] ?? [] {
                        try Task.checkCancellation()
                        if let oldDigest = try? ShelfFileStatus.digest(previous) { digests.insert(oldDigest) }
                    }
                }
                guard !unavailableDigests.contains(digest), digests.insert(digest).inserted else { continue }
                book.shelfDigest = digest
            }
            book.path = path; book.bookmark = (try? url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)) ?? book.bookmark
            books.append(book)
        }
        return PreparedManualBooks(books:books,identities:identities,existing:Set(catalog.books.map(\.id)))
    }
    private func applyManualBooks(_ prepared:PreparedManualBooks) throws {
        var next = catalog, known = Set(catalog.books.map{prepared.identities[$0.path] ?? $0.path})
        var digests = Set(catalog.books.filter{!prepared.existing.contains($0.id)}.compactMap(\.shelfDigest))
        for candidate in prepared.books where known.insert(candidate.path).inserted {
            if let digest = candidate.shelfDigest, !digests.insert(digest).inserted { continue }
            var book = next.pendingBooks?.first(where:{$0.id == candidate.id}) ?? candidate
            if book.shelfAuthor == nil { book.shelfAuthor = candidate.shelfAuthor }
            if book.shelfYear == nil { book.shelfYear = candidate.shelfYear }
            book.shelfDigest = candidate.shelfDigest ?? book.shelfDigest
            book.path = candidate.path; book.bookmark = candidate.bookmark; next.books.append(book)
            next.pendingBooks?.removeAll{$0.id == book.id}
        }
        if next != catalog { try applyShelfEdit(next,name:"添加书籍") }
    }
    func add(_ urls:[URL]) throws { try applyManualBooks(Self.prepareManualBooks(urls,catalog:catalog)) }
    func addInBackground(_ urls:[URL],bibliography:Bibliography? = nil) async throws {
        let snapshot = catalog
        let worker = Task.detached(priority:.utility) { try Self.prepareManualBooks(urls,catalog:snapshot) }
        var prepared = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        if let bibliography, prepared.books.count == 1 {
            if !bibliography.title.isEmpty { prepared.books[0].title = bibliography.title }
            if !bibliography.author.isEmpty { prepared.books[0].shelfAuthor = bibliography.author }
            if !bibliography.year.isEmpty { prepared.books[0].shelfYear = bibliography.year }
        }
        try Task.checkCancellation(); try applyManualBooks(prepared)
    }
    func update(_ book: LibraryBook) throws {
        var next = catalog
        guard let index = next.books.firstIndex(where: { $0.id == book.id }) else { throw FolioError(message: "书籍已不在书架中") }
        next.books[index] = book; try commit(next)
    }
    func acceptPending(_ ids: Set<UUID>) throws {
        var next = catalog
        let known = Set(next.books.map(\.path))
        next.books += (next.pendingBooks ?? []).filter { ids.contains($0.id) && !known.contains($0.path) }
        next.pendingBooks?.removeAll { ids.contains($0.id) }; try applyShelfEdit(next,name:"恢复书籍")
    }
    func removeBooks(_ ids: Set<UUID>) throws {
        var next = catalog
        let retained = Set((next.pendingBooks ?? []).map(\.id))
        if next.pendingBooks == nil { next.pendingBooks = [] }
        next.pendingBooks?.append(contentsOf: next.books.filter { ids.contains($0.id) && !retained.contains($0.id) })
        next.books.removeAll { ids.contains($0.id) }; try applyShelfEdit(next,name:"移出书架")
    }
    func addShelfTopic(_ raw:String,adding ids:Set<UUID> = []) throws -> String {
        guard let proposed = ShelfBrowse.topics([raw]).first, proposed.count <= 100 else {
            throw FolioError(message:"请输入 1 至 100 个字符的专题名")
        }
        let existing = shelfTopics.first { AnnotationFilter.folded($0) == AnnotationFilter.folded(proposed) }
        let topic = existing ?? proposed
        var next = catalog
        if existing == nil { next.shelfTopics = (next.shelfTopics ?? [])+[topic] }
        for index in next.books.indices where ids.contains(next.books[index].id) {
            let topics = next.books[index].shelfTopics
            next.books[index].topics = ShelfBrowse.topics(topics+[topic])
        }
        try applyShelfEdit(next,name:existing == nil ? "新建专题" : "加入专题")
        return topic
    }
    func updateShelfTopic(_ topic:String, replacement:String?) throws -> String? {
        let key = AnnotationFilter.folded(topic)
        guard shelfTopics.contains(where:{AnnotationFilter.folded($0) == key}) else { return nil }
        let name: String?
        if let replacement {
            guard let clean = ShelfBrowse.topics([replacement]).first, clean.count <= 100 else {
                throw FolioError(message:"请输入 1 至 100 个字符的专题名")
            }
            name = shelfTopics.first { $0 != topic && AnnotationFilter.folded($0) == AnnotationFilter.folded(clean) } ?? clean
        } else { name = nil }
        var next = catalog
        next.shelfTopics = ShelfBrowse.topics((next.shelfTopics ?? []).filter{AnnotationFilter.folded($0) != key} + (name.map{[$0]} ?? []))
        for index in next.books.indices {
            var book = next.books[index]
            guard book.shelfTopics.contains(where:{AnnotationFilter.folded($0) == key}) else { continue }
            book.topics = ShelfBrowse.topics(book.shelfTopics.filter{AnnotationFilter.folded($0) != key} + (name.map{[$0]} ?? []))
            if AnnotationFilter.folded(book.category) == key { book.category = "" }
            next.books[index] = book
        }
        try applyShelfEdit(next,name:name == nil ? "删除专题" : "重命名专题")
        return name
    }
    func editShelfBooks(_ ids:Set<UUID>, name:String, edit:(inout LibraryBook)->Void) throws {
        var next = catalog
        for index in next.books.indices where ids.contains(next.books[index].id) { edit(&next.books[index]) }
        if next != catalog { try applyShelfEdit(next,name:name) }
    }
    private func applyShelfEdit(_ next:Catalog,name:String) throws {
        guard catalog != next else { return }
        let previous = catalog
        try commit(next)
        shelfUndo = (previous,next)
        shelfUndoName = name
    }
    func undoShelfEdit() throws {
        guard let change = shelfUndo else { return }
        var next = catalog
        let before = Dictionary(change.before.books.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        let after = Dictionary(change.after.books.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        let changed = Set(before.keys).union(after.keys).filter{before[$0] != after[$0]}
        let current = Dictionary(next.books.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        guard changed.allSatisfy({current[$0] == after[$0]}),
              change.before.pendingBooks == change.after.pendingBooks || next.pendingBooks == change.after.pendingBooks,
              change.before.shelfTopics == change.after.shelfTopics || next.shelfTopics == change.after.shelfTopics else {
            throw FolioError(message:"相关条目已有其他修改，无法撤销这次操作")
        }
        next.books.removeAll { changed.contains($0.id) && before[$0.id] == nil }
        for index in next.books.indices where changed.contains(next.books[index].id) {
            if let previous = before[next.books[index].id] { next.books[index] = previous }
        }
        next.books += change.before.books.filter { changed.contains($0.id) && current[$0.id] == nil }
        if change.before.pendingBooks != change.after.pendingBooks { next.pendingBooks = change.before.pendingBooks }
        if change.before.shelfTopics != change.after.shelfTopics { next.shelfTopics = change.before.shelfTopics }
        try commit(next)
        shelfUndo = nil
        shelfUndoName = nil
    }
    func register(_ shortcut: ReadingShortcut, file: URL? = nil) throws {
        try shortcut.validate()
        var next = catalog
        let item = ManagedReadingShortcut(shortcut: shortcut, file: file, baseline: try file.map { try FileBaseline.capture($0) })
        if let file, let index = next.shortcuts.firstIndex(where: { $0.file?.standardizedFileURL == file.standardizedFileURL }) {
            var replacement = item; replacement.id = next.shortcuts[index].id; next.shortcuts[index] = replacement
        } else if file == nil, let index = next.shortcuts.firstIndex(where: { $0.file == nil && $0.shortcut.path == shortcut.path && $0.shortcut.mode == shortcut.mode && $0.shortcut.position == shortcut.position }) {
            next.shortcuts[index].shortcut = shortcut
        } else { next.shortcuts.append(item) }
        try commit(next)
    }
    func removeShortcut(_ id: UUID) throws {
        var next = catalog; next.shortcuts.removeAll { $0.id == id }; try commit(next)
    }
    func resolve(_ shortcut: ReadingShortcut) -> ReadingShortcut {
        var result = shortcut, seen = Set<String>()
        while let path = catalog.relocated[result.path], seen.insert(result.path).inserted { result.path = path; result.bookmark = nil }
        if result.path != shortcut.path, let book = book(path: result.path) { result.bookmark = book.bookmark }
        return result
    }
    /// Relinking never changes either original. Progress and metadata follow the explicitly chosen replacement.
    func relink(path oldPath: String, to url: URL, defaults: UserDefaults, validated:Bool = false, verifiedDigest:String? = nil) throws {
        guard Self.supports(url), FileManager.default.fileExists(atPath: url.path) else { throw FolioError(message: "请选择可读取的书籍文件") }
        if !validated, url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { throw FolioError(message: "无法读取这本 PDF，请先解锁或选择其他文件") }
        }
        let path = ReadingProgress.canonicalPath(url.path)
        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        var next = catalog
        let oldIdentity = ReadingProgress.canonicalPath(oldPath)
        let indices = next.books.indices.filter { ReadingProgress.canonicalPath(next.books[$0].path) == oldIdentity }
        if let index = indices.first {
            let id = next.books[index].id
            if let other = next.books.first(where: { $0.id != id && ReadingProgress.canonicalPath($0.path) == path }) {
                next.books[index].favorite = next.books[index].favorite || other.favorite
                next.books[index].topics = ShelfBrowse.topics(next.books[index].shelfTopics + other.shelfTopics)
                next.books[index].readingStatus = next.books[index].readingStatus ?? other.readingStatus
                next.books[index].shelfTags = ShelfBrowse.topics((next.books[index].shelfTags ?? [])+(other.shelfTags ?? []))
                next.books[index].shelfAuthor = next.books[index].shelfAuthor ?? other.shelfAuthor
                next.books[index].shelfPeriodical = next.books[index].shelfPeriodical ?? other.shelfPeriodical
                next.books[index].shelfYear = next.books[index].shelfYear ?? other.shelfYear
                next.books[index].shelfDigest = next.books[index].shelfDigest ?? other.shelfDigest
                if next.books[index].category.isEmpty { next.books[index].category = other.category }
                if !other.reflection.isEmpty { next.books[index].reflection += (next.books[index].reflection.isEmpty ? "" : "\n\n") + other.reflection }
                next.books.removeAll { $0.id == other.id }
            }
            if let index = next.books.firstIndex(where: { $0.id == id }) { next.books[index].path = path; next.books[index].bookmark = bookmark; next.books[index].shelfDigest = verifiedDigest ?? next.books[index].shelfDigest }
        } else if let i = next.pendingBooks?.firstIndex(where:{ ReadingProgress.canonicalPath($0.path) == oldIdentity }) {
            next.pendingBooks?[i].path = path; next.pendingBooks?[i].bookmark = bookmark
            if let verifiedDigest { next.pendingBooks?[i].shelfDigest = verifiedDigest }
        }
        // Redirect all aliases directly; moving a book back to an old path cannot form a cycle.
        for key in next.relocated.keys where next.relocated[key] == oldPath || next.relocated[key] == oldIdentity { next.relocated[key] = path }
        next.relocated.removeValue(forKey: path)
        if oldPath != path { next.relocated[oldPath] = path }
        if oldIdentity != path { next.relocated[oldIdentity] = path }
        for index in next.shortcuts.indices where ReadingProgress.canonicalPath(next.shortcuts[index].shortcut.path) == oldIdentity {
            next.shortcuts[index].shortcut.path = path; next.shortcuts[index].shortcut.bookmark = bookmark
        }
        try ReadingDocumentStore.relink(from: URL(fileURLWithPath: oldPath), to: url, storage: storage)
        try commit(next)
        let previous = ReadingProgress.load(path: oldPath, defaults: defaults), current = ReadingProgress.load(path: path, defaults: defaults)
        var progress = (previous.date ?? .distantPast) > (current.date ?? .distantPast) ? previous : current
        progress.visited.formUnion(previous.visited); progress.visited.formUnion(current.visited); progress.bookmark = bookmark
        if progress.title == nil { progress.title = book(path: path)?.title }
        if oldIdentity != path { ReadingProgress.clear(path: oldPath, defaults: defaults) }
        progress.save(path: path, defaults: defaults)
        didRelink?(oldPath,url)
    }
    func renameShortcut(_ id: UUID, title: String) throws {
        var next = catalog
        guard let index = next.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FolioError(message: "名称不能为空") }
        next.shortcuts[index].shortcut.title = title; try commit(next)
    }
    /// Update a known exported file only if it has not been externally replaced or edited.
    func exportShortcut(_ id: UUID, to target: URL) throws {
        guard let item = shortcuts.first(where: { $0.id == id }) else { return }
        let expected: FileBaseline
        if target.standardizedFileURL == item.file?.standardizedFileURL { guard let baseline = item.baseline else { throw FileConflict() }; expected = baseline }
        else { expected = try FileBaseline.capture(target) }
        try resolve(item.shortcut).write(to: target, expected: expected)
        var next = catalog
        if let index = next.shortcuts.firstIndex(where: { $0.id == id }) { next.shortcuts[index].file = target; next.shortcuts[index].baseline = try FileBaseline.capture(target); try commit(next) }
    }
}

extension WorkspaceStore {
    func openCurrentBookNotebook() {
        guard let workspace = commandWorkspace, let path = workspace.progressPath else { return }
        do {
            workspace.saveReadingRecord()
            notebookBook = library.book(path: path) ?? LibraryBook(path:path,title:workspace.displayName)
        } catch { present(error) }
    }
    func openLibraryBook(_ book: LibraryBook, resolvedFile:URL? = nil) throws {
        let shortcut = library.resolve(ReadingShortcut(path: book.path, title: book.title, position: ViewPosition(selection: 0), bookmark: book.bookmark))
        let url = try resolvedFile ?? shortcut.resolvedURL()
        if TextImport.handles(url) { openNote(url) } else { try openReadingShortcut(shortcut,resolvedFile:url) }
    }
}

@MainActor final class ManualShelfAddition:ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var task:Task<Void,Never>?
    private var token = UUID()
    func add(_ urls:[URL],to library:BookLibrary,bibliography:Bibliography? = nil) {
        cancel(); let current = UUID(); token = current; busy = true; message = "";let previous=library.books.count
        task = Task { [weak self] in
            do { try await library.addInBackground(urls,bibliography:bibliography); guard let self,self.token == current else { return }; self.busy = false;let added=library.books.count-previous;let skipped = max(0,urls.count-added);self.message = added == 0 ? "所选文献已在书架中" : "已添加 \(added) 本书籍" + (skipped == 0 ? "" : "，跳过 \(skipped) 份重复文件") }
            catch { guard let self,self.token == current else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已停止添加" : error.localizedDescription }
        }
    }
    func cancel() { token = UUID(); task?.cancel(); task = nil; busy = false }
}
