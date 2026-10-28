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
    }
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
            } catch { self.error = "书架未能读取，原记录保留：" + error.localizedDescription }
        }
    }
    private func commit(_ next: Catalog) throws {
        guard error == nil else { throw FolioError(message: error!) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        catalog = next
    }
    static func supports(_ url: URL) -> Bool { ["pdf", "kongfolio"].contains(url.pathExtension.lowercased()) || TextImport.handles(url) }
    func book(path: String) -> LibraryBook? { books.first { ReadingProgress.canonicalPath($0.path) == ReadingProgress.canonicalPath(path) } }
    func importHistory(defaults: UserDefaults) throws {
        var next = catalog
        for item in ReadingProgress.history(defaults: defaults) {
            guard next.relocated[item.path] == nil, !next.books.contains(where: { ReadingProgress.canonicalPath($0.path) == ReadingProgress.canonicalPath(item.path) }) else { continue }
            next.books.append(LibraryBook(path: item.path, title: item.title, bookmark: item.progress.bookmark, added: item.progress.date ?? Date()))
        }
        if next != catalog { try commit(next) }
    }
    func add(_ urls: [URL]) throws {
        var next = catalog
        for url in urls {
            guard Self.supports(url), FileManager.default.fileExists(atPath: url.path) else { throw FolioError(message: "请选择 PDF、项目或文本文件") }
            let path = ReadingProgress.canonicalPath(url.path)
            if next.books.contains(where: { ReadingProgress.canonicalPath($0.path) == path }) { continue }
            next.books.append(LibraryBook(path: path, title: url.deletingPathExtension().lastPathComponent,
                bookmark: try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)))
        }
        try commit(next)
    }
    func update(_ book: LibraryBook) throws {
        var next = catalog
        guard let index = next.books.firstIndex(where: { $0.id == book.id }) else { throw FolioError(message: "书籍已不在书架中") }
        next.books[index] = book; try commit(next)
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
        } else { next.books.append(LibraryBook(path: path, title: url.deletingPathExtension().lastPathComponent, bookmark: bookmark)) }
        // Redirect all aliases directly; moving a book back to an old path cannot form a cycle.
        for key in next.relocated.keys where next.relocated[key] == oldPath || next.relocated[key] == oldIdentity { next.relocated[key] = path }
        next.relocated.removeValue(forKey: path)
        if oldPath != path { next.relocated[oldPath] = path }
        if oldIdentity != path { next.relocated[oldIdentity] = path }
        for index in next.shortcuts.indices where ReadingProgress.canonicalPath(next.shortcuts[index].shortcut.path) == oldIdentity {
            next.shortcuts[index].shortcut.path = path; next.shortcuts[index].shortcut.bookmark = bookmark
        }
        try commit(next)
        let previous = ReadingProgress.load(path: oldPath, defaults: defaults), current = ReadingProgress.load(path: path, defaults: defaults)
        var progress = (previous.date ?? .distantPast) > (current.date ?? .distantPast) ? previous : current
        progress.visited.formUnion(previous.visited); progress.visited.formUnion(current.visited); progress.bookmark = bookmark
        if progress.title == nil { progress.title = book(path: path)?.title }
        ReadingProgress.clear(path: oldPath, defaults: defaults)
        progress.save(path: path, defaults: defaults)
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
        if target.standardizedFileURL == item.file?.standardizedFileURL { guard let baseline = item.baseline else { throw FileConflict() }; try baseline.verify(target) }
        try resolve(item.shortcut).write(to: target)
        var next = catalog
        if let index = next.shortcuts.firstIndex(where: { $0.id == id }) { next.shortcuts[index].file = target; next.shortcuts[index].baseline = try FileBaseline.capture(target); try commit(next) }
    }
}

extension WorkspaceStore {
    func openCurrentBookNotebook() {
        guard let workspace = commandWorkspace, let path = workspace.progressPath else { return }
        do {
            workspace.saveReadingRecord()
            try library.importHistory(defaults: readingDefaults)
            notebookBook = library.book(path: path)
        } catch { present(error) }
    }
    func openLibraryBook(_ book: LibraryBook) throws {
        let shortcut = library.resolve(ReadingShortcut(path: book.path, title: book.title, position: ViewPosition(selection: 0), bookmark: book.bookmark))
        let url = try shortcut.resolvedURL()
        if TextImport.handles(url) { openNote(url) } else { try openReadingShortcut(shortcut) }
    }
}
