import Foundation

/// Which pages of a book have been read, kept per file, so the reader can see how far they are and where to go on.
struct ReadingProgress: Equatable {
    var visited: Set<Int> = []
    var last = 0

    struct Chapter: Equatable {
        var title: String
        var depth: Int
        var firstPage: Int
        var pageCount: Int
        var visitedCount: Int
        var fraction: Double { pageCount == 0 ? 0 : Double(visitedCount) / Double(pageCount) }
    }

    func fraction(pageCount: Int) -> Double {
        pageCount == 0 ? 0 : Double(visited.filter { $0 < pageCount }.count) / Double(pageCount)
    }

    /// The first page after `page` that has not been read (wrapping round to the start), or nil when all have been.
    func nextUnread(after page: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        for offset in 1...pageCount {
            let candidate = (page + offset) % pageCount
            if !visited.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Each chapter of the table of contents (to the next entry of the same or a higher level) with how much of it has been read.
    static func chapters(outline: [OutlineEntry], visited: Set<Int>, pageCount: Int) -> [Chapter] {
        let entries = outline.enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
        var result: [Chapter] = []
        for (index, entry) in entries.enumerated() {
            let end = entries[(index + 1)...].first { $0.depth <= entry.depth }?.page ?? pageCount
            let count = max(0, min(end, pageCount) - entry.page)
            let read = visited.filter { $0 >= entry.page && $0 < min(end, pageCount) }.count
            result.append(Chapter(title: entry.label, depth: entry.depth, firstPage: entry.page, pageCount: count, visitedCount: read))
        }
        return result
    }

    // MARK: Storage

    /// {0,1,2,3,7} → "0-3,7"
    static func encode(_ pages: Set<Int>) -> String {
        var parts: [String] = []
        var run: (start: Int, end: Int)?
        for page in pages.sorted() {
            if let current = run, page == current.end + 1 { run = (current.start, page); continue }
            if let current = run { parts.append(current.start == current.end ? "\(current.start)" : "\(current.start)-\(current.end)") }
            run = (page, page)
        }
        if let current = run { parts.append(current.start == current.end ? "\(current.start)" : "\(current.start)-\(current.end)") }
        return parts.joined(separator: ",")
    }

    static func decode(_ text: String) -> Set<Int> {
        var pages = Set<Int>()
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { pages.insert(bounds[0]) }
            else if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 100_000 { pages.formUnion(bounds[0]...bounds[1]) }
        }
        return pages
    }

    private static func key(_ path: String) -> String { "KongFolio.progress." + path }

    static func load(path: String, defaults: UserDefaults = .standard) -> ReadingProgress {
        guard let stored = defaults.dictionary(forKey: key(path)) else { return ReadingProgress() }
        return ReadingProgress(visited: decode(stored["visited"] as? String ?? ""), last: stored["last"] as? Int ?? 0)
    }

    func save(path: String, defaults: UserDefaults = .standard) {
        defaults.set(["visited": Self.encode(visited), "last": last], forKey: Self.key(path))
    }

    static func clear(path: String, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(path)) }
}

extension Workspace {
    private var progressPath: String? { (projectURL ?? sourceURL)?.path }

    /// Counts the page as read once the reader has stayed on it for a moment (paging past quickly does not).
    func noteVisit(_ index: Int) {
        guard let path = progressPath else { return }
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.selection == index, index < self.count else { return }
            if self.readingProgressLoadedFor != path { self.readingProgress = ReadingProgress.load(path: path); self.readingProgressLoadedFor = path }
            self.readingProgress.last = index
            self.readingProgress.visited.insert(index)
            self.readingProgress.save(path: path)
        }
    }

    func refreshProgress() {
        guard let path = progressPath else { readingProgress = ReadingProgress(); return }
        readingProgress = ReadingProgress.load(path: path)
        progressLoadedFor = path
    }

    func clearProgress() {
        if let path = progressPath { ReadingProgress.clear(path: path) }
        readingProgress = ReadingProgress()
    }
}
