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
    }
    nonisolated static func prepareManualBooks(_ urls:[URL],catalog:Catalog) throws -> PreparedManualBooks {
        var identities = historyIdentities(catalog.books.map(\.path)+(catalog.pendingBooks ?? []).map(\.path)+urls.map(\.path))
        var known = Set(catalog.books.map{identities[$0.path] ?? $0.path})
        var pending:[String:LibraryBook] = [:]
        for book in catalog.pendingBooks ?? [] { pending[identities[book.path] ?? book.path] = book }
        var books:[LibraryBook] = []
        for url in urls {
            try Task.checkCancellation()
            guard supports(url),FileManager.default.fileExists(atPath:url.path) else { throw FolioError(message:"请选择可读取的 PDF、项目或文本文件") }
            let path = identities[url.path] ?? ReadingProgress.canonicalPath(url.path); identities[url.path] = path
            guard known.insert(path).inserted else { continue }
            var book = pending[path] ?? LibraryBook(path:path,title:url.deletingPathExtension().lastPathComponent)
            book.path = path; book.bookmark = (try? url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)) ?? book.bookmark
            books.append(book)
        }
        return PreparedManualBooks(books:books,identities:identities)
    }
    private func applyManualBooks(_ prepared:PreparedManualBooks) throws {
        var next = catalog, known = Set(catalog.books.map{prepared.identities[$0.path] ?? $0.path})
        for candidate in prepared.books where known.insert(candidate.path).inserted {
            var book = next.pendingBooks?.first(where:{$0.id == candidate.id}) ?? candidate
            book.path = candidate.path; book.bookmark = candidate.bookmark; next.books.append(book)
            next.pendingBooks?.removeAll{$0.id == book.id}
        }
        if next != catalog { try commit(next) }
    }
    func add(_ urls:[URL]) throws { try applyManualBooks(Self.prepareManualBooks(urls,catalog:catalog)) }
    func addInBackground(_ urls:[URL]) async throws {
        let snapshot = catalog
        let worker = Task.detached(priority:.utility) { try Self.prepareManualBooks(urls,catalog:snapshot) }
        let prepared = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
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
        next.pendingBooks?.removeAll { ids.contains($0.id) }; try commit(next)
    }
    func removeBooks(_ ids: Set<UUID>) throws {
        var next = catalog
        let retained = Set((next.pendingBooks ?? []).map(\.id))
        if next.pendingBooks == nil { next.pendingBooks = [] }
        next.pendingBooks?.append(contentsOf: next.books.filter { ids.contains($0.id) && !retained.contains($0.id) })
        next.books.removeAll { ids.contains($0.id) }; try commit(next)
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
        if let book = book(path: result.path), result.path != shortcut.path { result.bookmark = book.bookmark }
        return result
    }
    /// Relinking never changes either original. Progress and metadata follow the explicitly chosen replacement.
    func relink(path oldPath: String, to url: URL, defaults: UserDefaults) throws {
        guard Self.supports(url), FileManager.default.fileExists(atPath: url.path) else { throw FolioError(message: "请选择可读取的书籍文件") }
        if url.pathExtension.lowercased() == "pdf" {
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
                if next.books[index].category.isEmpty { next.books[index].category = other.category }
                if !other.reflection.isEmpty { next.books[index].reflection += (next.books[index].reflection.isEmpty ? "" : "\n\n") + other.reflection }
                next.books.removeAll { $0.id == other.id }
            }
            if let index = next.books.firstIndex(where: { $0.id == id }) { next.books[index].path = path; next.books[index].bookmark = bookmark }
        } else if let i = next.pendingBooks?.firstIndex(where:{ ReadingProgress.canonicalPath($0.path) == oldIdentity }) {
            next.pendingBooks?[i].path = path; next.pendingBooks?[i].bookmark = bookmark
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
        ReadingProgress.clear(path: oldPath, defaults: defaults)
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
    func openLibraryBook(_ book: LibraryBook) throws {
        let shortcut = library.resolve(ReadingShortcut(path: book.path, title: book.title, position: ViewPosition(selection: 0), bookmark: book.bookmark))
        let url = try shortcut.resolvedURL()
        if TextImport.handles(url) { openNote(url) } else { try openReadingShortcut(shortcut) }
    }
}

@MainActor final class ManualShelfAddition:ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var task:Task<Void,Never>?
    private var token = UUID()
    func add(_ urls:[URL],to library:BookLibrary) {
        cancel(); let current = UUID(); token = current; busy = true; message = ""
        task = Task { [weak self] in
            do { try await library.addInBackground(urls); guard let self,self.token == current else { return }; self.busy = false; self.message = "手动添加已完成" }
            catch { guard let self,self.token == current else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已停止添加" : error.localizedDescription }
        }
    }
    func cancel() { token = UUID(); task?.cancel(); task = nil; busy = false }
}
