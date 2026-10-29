import Foundation
import PDFKit

struct ReadingGroup: Codable, Identifiable {
    struct Book: Codable {
        var path: String
        var position: ViewPosition
        var layout: ReadingLayout
        var partner: Int?
        var sync = false
    }
    var id = UUID()
    var name: String
    var books: [Book]
    var selected = 0
}
struct PrintedPageSegment: Codable, Identifiable, Equatable {
    enum Style: String, Codable, CaseIterable { case decimal = "数字", roman = "罗马数字", none = "无页码" }
    var id = UUID()
    var start: Int
    var end: Int
    var first = 1
    var prefix = ""
    var style = Style.decimal
    func label(_ page: Int) -> String? {
        guard start >= 0, end >= start, (start...end).contains(page), first > 0, first < 1_000_000, page-start < 1_000_000, style != .none else { return nil }
        let n = first + page - start
        return prefix + (style == .roman ? Self.roman(n) : String(n))
    }
    static func roman(_ n: Int) -> String {
        guard (1...3999).contains(n) else { return String(n) }
        var n = n, result = ""
        for (value, text) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
            while n >= value { result += text; n -= value }
        }
        return result.lowercased()
    }
    static func validate(_ values: [Self], count: Int) throws {
        var last = -1
        for value in values.sorted(by: { $0.start < $1.start }) {
            guard value.start > last, value.end >= value.start, value.end < count, value.first > 0, value.first < 1_000_000 else { throw FolioError(message: "页码段重叠、超出文档或起始号码无效") }
            last = value.end
        }
    }
}
struct PeriodicalRecord: Codable, Equatable {
    var journal = ""
    var year = ""
    var volume = ""
    var issue = ""
    var date = ""
    var edition = ""
    func validate() throws {
        if citation.isEmpty { return }
        guard !journal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolioError(message: "请填写刊名") }
        if !date.isEmpty {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { throw FolioError(message: "日期请使用有效的 YYYY-MM-DD") }
        }
    }
    var citation: String { [journal,year,volume,issue,date,edition].filter { !$0.isEmpty }.joined(separator: "，") }
}
struct ScopedCorrection: Codable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
    var scope = "全局"
    var enabled = true
    func applies(path: String, project: String) -> Bool { enabled && (scope == "全局" || scope == path || (!project.isEmpty && scope == project)) }
}
struct ResearchAnnotation: Codable, Identifiable {
    var id: String { key }
    var key: String
    var path: String
    var page: Int
    var quote: String
    var comment: String
    var kind: String
    var color: String
    var tags: [String]
    var modified: Date
}
struct ResearchFilter: Codable, Identifiable {
    var id = UUID()
    var name: String
    var text = ""
    var kind = ""
    var color = ""
    var tag = ""
    var after: Date?
    var before: Date?
    var windowDays: Int? = nil
    func matches(_ note: ResearchAnnotation) -> Bool {
        let lower = windowDays.map { Date().addingTimeInterval(-Double(max(0,$0))*86400) } ?? after
        return (text.isEmpty || AnnotationFilter.folded(note.quote + note.comment).contains(AnnotationFilter.folded(text))) &&
        (kind.isEmpty || note.kind == kind) && (color.isEmpty || note.color == color) &&
        (tag.isEmpty || note.tags.contains(tag)) && (lower == nil || note.modified >= lower!) && (before == nil || note.modified <= before!)
    }
}
struct EditionCorrespondence: Codable, Identifiable {
    struct Pair: Codable, Equatable { var left: Int; var right: Int; var title = "" }
    var id = UUID()
    var name: String
    var leftPath: String
    var rightPath: String
    var pairs: [Pair]
    func validate(leftCount: Int, rightCount: Int) throws {
        let sorted = pairs.sorted { $0.left < $1.left }
        guard !pairs.isEmpty, leftPath != rightPath,
              pairs.allSatisfy({ (0..<leftCount).contains($0.left) && (0..<rightCount).contains($0.right) }),
              Set(pairs.map(\.left)).count == pairs.count, Set(pairs.map(\.right)).count == pairs.count,
              zip(sorted,sorted.dropFirst()).allSatisfy({ $0.right < $1.right }) else { throw FolioError(message: "版本对应页重复、越界、顺序不一致，或选择了同一文件") }
    }
    func isLeft(_ path: String?) -> Bool { path.map { ReadingProgress.canonicalPath($0) == ReadingProgress.canonicalPath(leftPath) } ?? false }
    func contains(_ path: String?) -> Bool { isLeft(path) || (path.map { ReadingProgress.canonicalPath($0) == ReadingProgress.canonicalPath(rightPath) } ?? false) }
    func mapped(_ page: Int, fromLeft: Bool) -> Int? {
        let entries = pairs.filter { $0.left >= 0 && $0.right >= 0 && $0.left < 1_000_000 && $0.right < 1_000_000 }.sorted { (fromLeft ? $0.left : $0.right) < (fromLeft ? $1.left : $1.right) }
        guard let anchor = entries.last(where: { (fromLeft ? $0.left : $0.right) <= page }) else { return nil }
        return (fromLeft ? anchor.right : anchor.left) + page - (fromLeft ? anchor.left : anchor.right)
    }
}
struct CitationTemplate: Codable {
    var text = "{author}：《{title}》，{periodical}，第{page}页。\n{quote}\n{link}"
    func render(author: String, title: String, periodical: String, page: String, quote: String, link: String) -> String {
        var result = text
        for (key,value) in [("author",author),("title",title),("periodical",periodical),("page",page),("quote",quote),("link",link)] { result = result.replacingOccurrences(of: "{" + key + "}", with: value) }
        return result
    }
}
@MainActor final class ResearchStore: ObservableObject {
    struct State: Codable {
        var version = 1
        var groups: [ReadingGroup] = []
        var identities: [String: String]? = nil
        var labels: [String: [PrintedPageSegment]] = [:]
        var periodicals: [String: PeriodicalRecord] = [:]
        var dictionary: [ScopedCorrection] = []
        var filters: [ResearchFilter] = []
        var annotations: [ResearchAnnotation] = []
        var editions: [EditionCorrespondence] = []
        var citation = CitationTemplate()
    }
    let storage: URL
    @Published private(set) var state = State()
    @Published private(set) var error: String?
    var url: URL { storage.appendingPathComponent("Research/catalog.json") }
    init(storage: URL) {
        self.storage = storage
        if FileManager.default.fileExists(atPath: url.path) {
            do { let value = try JSONDecoder().decode(State.self, from: Data(contentsOf: url)); guard value.version == 1 else { throw FolioError(message: "研究资料版本不受支持") }; state = value }
            catch { self.error = "研究资料未能读取，原文件保留：" + error.localizedDescription }
        }
    }
    func update(_ change: (inout State) throws -> Void) throws {
        guard error == nil else { throw FolioError(message: error!) }
        var next = state; try change(&next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic); state = next
    }
    func merge(_ other: State) throws {
        try update { next in
            for var group in other.groups { if next.groups.contains(where: { $0.id == group.id }) { group.id = UUID() }; next.groups.append(group) }
            if next.identities == nil { next.identities = [:] }
            next.identities?.merge(other.identities ?? [:]) { current, _ in current }
            next.labels.merge(other.labels) { current, _ in current }
            next.periodicals.merge(other.periodicals) { current, _ in current }
            next.dictionary += other.dictionary.filter { old in !next.dictionary.contains(where: { $0.id == old.id }) }
            next.filters += other.filters.filter { old in !next.filters.contains(where: { $0.id == old.id }) }
            next.annotations += other.annotations.filter { old in !next.annotations.contains(where: { $0.key == old.key }) }
            next.editions += other.editions.filter { old in !next.editions.contains(where: { $0.id == old.id }) }
        }
    }
    func relink(from old: String, to new: URL) throws {
        let oldKey = state.labels.keys.first { ReadingProgress.canonicalPath($0) == ReadingProgress.canonicalPath(old) } ?? old
        let identity = state.identities?[oldKey]
        let confirmed = identity != nil && identity == (try? FileBaseline.capture(new).digest)
        try update { value in
            for key in value.periodicals.keys.filter({ ReadingProgress.canonicalPath($0) == ReadingProgress.canonicalPath(old) }) {
                if let periodical = value.periodicals.removeValue(forKey: key), value.periodicals[new.path] == nil { value.periodicals[new.path] = periodical }
            }
            for i in value.groups.indices { for j in value.groups[i].books.indices where ReadingProgress.canonicalPath(value.groups[i].books[j].path) == ReadingProgress.canonicalPath(old) { value.groups[i].books[j].path = new.path } }
            if confirmed {
                if let labels = value.labels.removeValue(forKey: oldKey), value.labels[new.path] == nil { value.labels[new.path] = labels }
                if value.identities == nil { value.identities = [:] }; value.identities?[new.path] = identity
                for i in value.annotations.indices where value.annotations[i].path == oldKey { value.annotations[i].path = new.path; value.annotations[i].key = new.path + ":" + value.annotations[i].key.dropFirst(oldKey.count+1) }
                for i in value.editions.indices { if value.editions[i].leftPath == oldKey { value.editions[i].leftPath = new.path }; if value.editions[i].rightPath == oldKey { value.editions[i].rightPath = new.path } }
            }
        }
    }
    func segment(path: String, page: Int) -> PrintedPageSegment? {
        let values = state.labels[path] ?? state.labels.first { ReadingProgress.canonicalPath($0.key) == ReadingProgress.canonicalPath(path) }?.value
        return values?.first(where: { $0.start <= page && $0.end >= page })
    }
    func label(path: String, page: Int) -> String? { segment(path: path, page: page)?.label(page) }
    func displayLabel(path: String, page: Int, fallback: String) -> String {
        if let segment = segment(path: path, page: page) { return segment.label(page) ?? "无印刷页码" }
        return fallback
    }
    func periodical(path: String) -> PeriodicalRecord? { state.periodicals[path] ?? state.periodicals.first { ReadingProgress.canonicalPath($0.key) == ReadingProgress.canonicalPath(path) }?.value }
    func page(path: String, label: String, count: Int) -> Int? { (0..<count).first { self.label(path: path, page: $0) == label } }
    func rules(path: String, project: String) -> [ReplacementRule] { state.dictionary.filter { $0.applies(path: path, project: project) }.map { ReplacementRule(from: $0.from, to: $0.to) } }
    func periodicalProblems() -> [String] {
        let grouped = Dictionary(grouping: state.periodicals.map { ($0.key,$0.value) }, by: { $0.1.journal + "/" + $0.1.year + "/" + $0.1.volume })
        var result: [String] = []
        for (name, books) in grouped where !name.replacingOccurrences(of: "/", with: "").isEmpty {
            let numbers = books.compactMap { Int($0.1.issue) }.sorted()
            for n in Set(numbers) where numbers.filter({ $0 == n }).count > 1 { result.append(name + " 重复第 \(n) 期") }
            if let low = numbers.first, let high = numbers.last, high - low < 10000 {
                let missing = (low...high).filter { !numbers.contains($0) }; if !missing.isEmpty { result.append(name + " 范围内缺期：" + missing.map(String.init).joined(separator: "、")) }
            }
        }
        return result.sorted()
    }
}
