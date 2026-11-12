import Foundation

struct ShelfSavedFilter: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var scope: String
    var query: String
    var year: String
    var periodical: String
    var status: ShelfReadingStatus?
    var withExcerpts: Bool
}

struct ShelfImportDraft: Identifiable {
    var id: URL { url }
    let url: URL
    var title: String
    var periodical: String
    var year: String
    var volume: String
    var issue: String
    var topic = ""

    init(_ url:URL) {
        self.url = url
        title = url.deletingPathExtension().lastPathComponent
        let inferred = ShelfText.infer(title)
        periodical = inferred.periodical
        year = inferred.year
        volume = inferred.volume
        issue = inferred.issue
    }

    func apply(to book:inout LibraryBook) {
        func clean(_ value:String) -> String? {
            let trimmed = value.trimmingCharacters(in:.whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let title = clean(title) { book.title = title }
        book.shelfPeriodical = clean(periodical) ?? book.shelfPeriodical
        book.shelfYear = clean(year) ?? book.shelfYear
        book.shelfVolume = clean(volume) ?? book.shelfVolume
        book.shelfIssue = clean(issue) ?? book.shelfIssue
        if let topic = clean(topic) { book.topics = ShelfBrowse.topics(book.shelfTopics+[topic]) }
    }
}

enum ShelfText {
    private static let keys: NSCache<NSString,NSString> = { let cache = NSCache<NSString,NSString>();cache.countLimit = 8192;return cache }()
    private static let numberPattern = #"第?\s*([0-9０-９〇零一二三四五六七八九十百千万兩两]+)\s*([期卷])"#
    private static let numbered = try! NSRegularExpression(pattern:numberPattern)
    private static let looseYear = try! NSRegularExpression(pattern:#"(?<![0-9])((?:17|18|19|20)[0-9]{2})(?![0-9])"#)

    static func key(_ value:String) -> String {
        if value.isEmpty { return "" }
        if let cached = keys.object(forKey:value as NSString) { return cached as String }
        let text = AnnotationFilter.folded(value.folding(options:.widthInsensitive,locale:nil))
        let result = NSMutableString(string:text)
        for match in numbered.matches(in:text,range:NSRange(location:0,length:result.length)).reversed() {
            if let n = number(result.substring(with:match.range(at:1))) {
                let unit = result.substring(with:match.range(at:2))
                result.replaceCharacters(in:match.range,with:String(n)+unit)
            }
        }
        let normalized = (result as String).trimmingCharacters(in:.whitespacesAndNewlines)
        keys.setObject(normalized as NSString,forKey:value as NSString)
        return normalized
    }

    static func number(_ value:String) -> Int? {
        let text = value.folding(options:.widthInsensitive,locale:nil)
        if let decimal = Int(text) { return decimal }
        let digits = ["〇":0,"零":0,"一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9,"两":2,"兩":2]
        let units = ["十":10,"百":100,"千":1000,"万":10000,"萬":10000]
        guard !text.isEmpty, text.count < 16 else { return nil }
        if text.allSatisfy({digits[String($0)] != nil}) {
            return Int(text.compactMap{digits[String($0)]}.map(String.init).joined())
        }
        var total = 0, current = 0
        for char in text.map(String.init) {
            if let digit = digits[char] { current = digit }
            else if let unit = units[char] { total += max(1,current)*unit;current = 0 }
            else { return nil }
        }
        return total+current
    }

    private final class Parsed {
        let periodical:String, year:String, volume:String, issue:String
        init(_ p:String,_ y:String,_ v:String,_ i:String) { periodical = p;year = y;volume = v;issue = i }
    }
    private static let inferred: NSCache<NSString,Parsed> = { let cache = NSCache<NSString,Parsed>();cache.countLimit = 4096;return cache }()

    static func infer(_ name:String) -> (periodical:String,year:String,volume:String,issue:String) {
        if let cached = inferred.object(forKey:name as NSString) {
            return (cached.periodical,cached.year,cached.volume,cached.issue)
        }
        let source = name as NSString
        let range = NSRange(location:0,length:source.length)
        let yearMatch = looseYear.firstMatch(in:name,range:range)
        let year = yearMatch.map{source.substring(with:$0.range(at:1))} ?? ""
        var volume = "", issue = ""
        let matches = numbered.matches(in:name,range:range)
        for match in matches {
            let value = source.substring(with:match.range(at:1))
            if source.substring(with:match.range(at:2)) == "卷" { volume = value }
            else { issue = value }
        }
        let parts = name.split(whereSeparator:{$0 == "_" || $0 == "＿"})
            .map{$0.trimmingCharacters(in:.whitespaces)}
        if issue.isEmpty, parts.count >= 3, parts[parts.count-2] == year,
           let last = parts.last, number(last) != nil { issue = last }
        let end = [yearMatch?.range.location,matches.first?.range.location].compactMap{$0}.min()
        let periodical = (volume.isEmpty && issue.isEmpty ? nil : end).map {
            source.substring(to:$0).trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"_-–—·《》（(")))
        } ?? ""
        inferred.setObject(Parsed(periodical,year,volume,issue),forKey:name as NSString)
        return (periodical,year,volume,issue)
    }

    static func issueOrder(_ books:[LibraryBook]) -> [LibraryBook] {
        books.sorted { lhs,rhs in
            let a = [lhs.issueMetadata.year,lhs.issueMetadata.volume,lhs.issueMetadata.issue].map{number($0) ?? .max}
            let b = [rhs.issueMetadata.year,rhs.issueMetadata.volume,rhs.issueMetadata.issue].map{number($0) ?? .max}
            if a != b { return a.lexicographicallyPrecedes(b) }
            let cmp = lhs.title.localizedStandardCompare(rhs.title)
            return cmp == .orderedSame ? lhs.path < rhs.path : cmp == .orderedAscending
        }
    }

    static func versions(_ books:[LibraryBook]) -> [UUID:[LibraryBook]] {
        var groups: [String:[LibraryBook]] = [:]
        for book in books where book.isPDF {
            let periodical = key(book.issueMetadata.periodical)
            let issue = key(book.issueMetadata.issue)
            let identity = !periodical.isEmpty && !issue.isEmpty
                ? ["刊",periodical,key(book.issueMetadata.year),key(book.issueMetadata.volume),issue].joined(separator:"|")
                : "书|"+key(book.title)
            groups[identity,default:[]].append(book)
        }
        var result: [UUID:[LibraryBook]] = [:]
        for group in groups.values where group.count > 1 {
            for book in group {
                result[book.id] = Array(group.lazy.filter { $0.id != book.id && (book.shelfDigest == nil || book.shelfDigest != $0.shelfDigest) }.prefix(30))
            }
        }
        return result
    }
}

struct ShelfRecordSummary {
    var counts: [String:Int] = [:]
    var recent: [ReadingLibraryItem] = []
    var hasExcerpts: Bool { counts["摘录",default:0] > 0 }

    static func index(_ state:ReadingJournalState) -> [String:Self] {
        var results: [String:Self] = [:]
        for item in ReadingLibraryItem.results(state) {
            if Task.isCancelled { break }
            let paths = Set(item.citations053.map{ReadingBookIdentity.key($0.source.path)}).subtracting([""])
            let kind = item.kind == "图片摘录" ? "摘录" : item.kind
            for path in paths {
                results[path,default:Self()].counts[kind,default:0] += 1
                if results[path,default:Self()].recent.count < 3 { results[path,default:Self()].recent.append(item) }
            }
        }
        return results
    }
}
