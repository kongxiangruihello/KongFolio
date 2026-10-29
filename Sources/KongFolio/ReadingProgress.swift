import Foundation

/// Which pages of a book have been read, kept per file, so the reader can see how far they are and where to go on.
struct ReadingProgress: Equatable, Codable {
    var visited: Set<Int> = []
    var last = 0
    /// When a page was last counted as read (0.34), so KongSeek can list recently read books.
    var date: Date? = nil
    /// Pages in the document at that time (0.34), for “读到第 N 页 / 共 M 页” in KongSeek.
    var pages = 0
    var x: Double? = nil
    var y: Double? = nil
    var scale: Double? = nil
    var layout: ReadingLayout? = nil
    var title: String? = nil
    var bookmark: Data? = nil

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
    static func canonicalPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }

    static func load(path: String, defaults: UserDefaults = .standard) -> ReadingProgress {
        guard let stored = defaults.dictionary(forKey: key(path)) ?? defaults.dictionary(forKey: key(canonicalPath(path))) else { return ReadingProgress() }
        return ReadingProgress(visited: decode(stored["visited"] as? String ?? ""), last: stored["last"] as? Int ?? 0,
                               date: (stored["date"] as? Double).map { Date(timeIntervalSince1970: $0) }, pages: stored["pages"] as? Int ?? 0,
                               x: finite(stored["x"] as? Double), y: finite(stored["y"] as? Double),
                               scale: validScale(stored["scale"] as? Double),
                               layout: (stored["layout"] as? String).flatMap(ReadingLayout.init(rawValue:)), title: stored["title"] as? String, bookmark: stored["bookmark"] as? Data)
    }

    /// Stored as a plain dictionary under "KongFolio.progress.<path>" in KongFolio's preferences; KongSeek reads
    /// the same keys (visited, last, date, pages), so keep them stable.
    func save(path: String, defaults: UserDefaults = .standard) {
        var stored: [String: Any] = ["visited": Self.encode(visited), "last": last]
        if let date { stored["date"] = date.timeIntervalSince1970 }
        if pages > 0 { stored["pages"] = pages }
        if let x = Self.finite(x), let y = Self.finite(y) { stored["x"] = x; stored["y"] = y }
        if let scale = Self.validScale(scale) { stored["scale"] = scale }
        if let layout { stored["layout"] = layout.rawValue }
        if let title { stored["title"] = title }
        if let bookmark { stored["bookmark"] = bookmark }
        defaults.set(stored, forKey: Self.key(path))
        let canonical = Self.canonicalPath(path)
        if canonical != path { defaults.set(stored, forKey: Self.key(canonical)) }
    }

    /// The page to reopen at: the last page read, when it is past the first page and still in the document.
    func resumePage(pageCount: Int) -> Int? {
        last > 0 && last < pageCount ? last : nil
    }

    static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
    static func validScale(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 && $0 <= 64 ? $0 : nil } }
    func resumePosition(pageCount: Int) -> ViewPosition? {
        guard pageCount > 0, last >= 0, last < pageCount, date != nil || !visited.isEmpty else { return nil }
        return ViewPosition(selection: last, x: Self.finite(x), y: Self.finite(y), scale: Self.validScale(scale))
    }
    struct HistoryItem: Identifiable {
        var path: String
        var progress: ReadingProgress
        var id: String { path }
        var title: String { progress.title ?? URL(fileURLWithPath: path).lastPathComponent }
    }
    static func history(defaults: UserDefaults = .standard) -> [HistoryItem] {
        let prefix = "KongFolio.progress."
        let records: [HistoryItem] = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix + "/") }.compactMap { key -> HistoryItem? in
            let path = String(key.dropFirst(prefix.count)), progress = load(path: path, defaults: defaults)
            guard progress.last >= 0, progress.date != nil || !progress.visited.isEmpty else { return nil }
            return HistoryItem(path: path, progress: progress)
        }
        var unique: [String: HistoryItem] = [:]
        for record in records.sorted(by: { $0.path < $1.path }) {
            let identity = canonicalPath(record.path)
            if let old = unique[identity], (old.progress.date ?? .distantPast) >= (record.progress.date ?? .distantPast) { continue }
            unique[identity] = record
        }
        return unique.values.sorted { a, b in
            if a.progress.date != b.progress.date { return (a.progress.date ?? .distantPast) > (b.progress.date ?? .distantPast) }
            return a.path < b.path
        }
    }
    static func clear(path: String, defaults: UserDefaults = .standard) {
        let prefix = "KongFolio.progress.", canonical = canonicalPath(path)
        for storedKey in defaults.dictionaryRepresentation().keys where storedKey.hasPrefix(prefix + "/") {
            if canonicalPath(String(storedKey.dropFirst(prefix.count))) == canonical { defaults.removeObject(forKey: storedKey) }
        }
    }
}

extension Workspace {
    var progressPath: String? { (projectURL ?? sourceURL)?.path }

    /// Location is saved immediately; only the visited-page count waits for a deliberate pause.
    func noteVisit(_ index: Int) {
        guard index == selection, (0..<count).contains(index), let path = progressPath else { return }
        saveReadingRecord()
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.progressPath == path, self.selection == index, index < self.count else { return }
            self.saveReadingRecord(markVisited: true)
        }
    }
    func scheduleReadingRecord() {
        guard let path = progressPath, count > 0 else { return }
        readingSaveTask?.cancel()
        readingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, self.progressPath == path else { return }
            self.saveReadingRecord()
        }
    }
    func saveReadingRecord(capture: Bool = true, markVisited: Bool = false) {
        guard let path = progressPath, count > 0, (0..<count).contains(selection) else { return }
        if capture { captureReadingPosition(scheduleSave: false) }
        var record = ReadingProgress.load(path: path, defaults: readingDefaults)
        record.last = selection; record.pages = count; record.date = Date(); record.title = displayName
        record.x = readingPoint.map { Double($0.x) }; record.y = readingPoint.map { Double($0.y) }
        record.scale = readingScale; record.layout = readingLayout
        if record.bookmark == nil { record.bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        if markVisited { record.visited.insert(selection) }
        readingProgress = record; progressLoadedFor = path
        record.save(path: path, defaults: readingDefaults)
    }
    func refreshProgress() {
        guard let path = progressPath else { readingProgress = ReadingProgress(); return }
        readingProgress = ReadingProgress.load(path: path, defaults: readingDefaults)
        progressLoadedFor = path
    }
    func clearProgress() {
        progressTask?.cancel(); readingSaveTask?.cancel()
        if let path = progressPath { ReadingProgress.clear(path: path, defaults: readingDefaults) }
        readingProgress = ReadingProgress()
    }
    func prepareReadingResume(path: String, enabled: Bool = AppInterface.resumeReading) {
        guard pendingView == nil, pendingReveal == nil, enabled else { return }
        let progress = ReadingProgress.load(path: path, defaults: readingDefaults)
        guard let position = progress.resumePosition(pageCount: count) else { return }
        pendingView = position; pendingReadingLayout = progress.layout
    }
}
