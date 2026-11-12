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
        enum Identity: Hashable { case issue(ShelfIssueKey), book(String) }
        let groups = Dictionary(grouping:books.filter(\.isPDF)) { book in
            ShelfIssueKey(book.issueMetadata).map(Identity.issue) ?? .book(key(book.title))
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
    var latestNote: ReadingLibraryItem?
    var latestVerifiedExcerpt: ReadingLibraryItem?
    var hasExcerpts: Bool { counts["摘录",default:0] > 0 }

    static func index(_ state:ReadingJournalState) -> [String:Self] {
        var results: [String:Self] = [:]
        for item in ReadingLibraryItem.results(state) {
            if Task.isCancelled { break }
            let paths = Set(item.citations053.map{ReadingBookIdentity.key($0.source.path)}).subtracting([""])
            let kind = item.kind == "图片摘录" ? "摘录" : item.kind
            for path in paths {
                results[path,default:Self()].counts[kind,default:0] += 1
                if kind == "笔记", results[path]?.latestNote.map({$0.modified053 >= item.modified053}) != true {
                    results[path,default:Self()].latestNote = item
                }
                if kind == "摘录", item.extras053.review == .verified,
                   results[path]?.latestVerifiedExcerpt.map({$0.modified053 >= item.modified053}) != true {
                    results[path,default:Self()].latestVerifiedExcerpt = item
                }
                if results[path,default:Self()].recent.count < 3 { results[path,default:Self()].recent.append(item) }
            }
        }
        return results
    }
}

enum ShelfEdition: String, Codable, CaseIterable {
    case original = "原刊扫描"
    case reprint = "重印本"
    case ocr = "OCR 版"
    case other = "其他版本"
}

struct ShelfIssueKey: Hashable {
    let publication: String
    let year: String
    let volume: String
    let issue: String

    init?(_ metadata: (periodical:String,year:String,volume:String,issue:String)) {
        publication = ShelfText.key(metadata.periodical)
        year = Self.component(metadata.year, suffix:"年")
        volume = Self.component(metadata.volume, suffix:"卷")
        issue = Self.component(metadata.issue, suffix:"期")
        guard !publication.isEmpty, !issue.isEmpty else { return nil }
    }

    static func component(_ value:String,suffix:Character) -> String {
        let folded = ShelfText.key(value)
        let plain = folded.last == suffix ? String(folded.dropLast()) : folded
        return ShelfText.number(plain).map(String.init) ?? folded
    }

    func missingIssues(toward other:Self) -> String? {
        guard publication == other.publication, year == other.year, volume == other.volume,
              !year.isEmpty || !volume.isEmpty, let a = Int(issue), let b = Int(other.issue),
              min(a,b) >= 0, max(a,b)-min(a,b) > 1 else { return nil }
        let first = min(a,b)+1, last = max(a,b)-1
        return first == last ? "书架缺少第 \(first) 期" : "书架缺少第 \(first)–\(last) 期"
    }
}

struct ShelfPeriodicalIndex {
    struct Issue: Identifiable {
        let id: ShelfIssueKey
        let editions: [LibraryBook]
        var preferred: LibraryBook { editions.first(where:{$0.shelfPreferredEdition == true}) ?? editions[0] }
    }
    struct Group: Identifiable {
        struct Key: Hashable { let year:String; let volume:String }
        let id: Key
        let issues: [Issue]
        var title: String {
            [id.year.isEmpty ? "年代未填" : id.year+" 年",
             id.volume.isEmpty ? "卷号未填" : "第 "+id.volume+" 卷"].joined(separator:" · ")
        }
    }

    let issues: [Issue]
    init(_ books:[LibraryBook],publication:String) {
        let publication = ShelfText.key(publication)
        let entries = books.compactMap { book -> (ShelfIssueKey,LibraryBook)? in
            guard book.isPDF, let key = ShelfIssueKey(book.issueMetadata), key.publication == publication else { return nil }
            return (key,book)
        }
        issues = Dictionary(grouping:entries,by:{ $0.0 }).map { key,values in
            Issue(id:key,editions:ShelfText.issueOrder(values.map{ $0.1 }))
        }.sorted { lhs,rhs in
            let a = [lhs.id.year,lhs.id.volume,lhs.id.issue].map{Int($0) ?? .max}
            let b = [rhs.id.year,rhs.id.volume,rhs.id.issue].map{Int($0) ?? .max}
            if a != b { return a.lexicographicallyPrecedes(b) }
            return [lhs.id.year,lhs.id.volume,lhs.id.issue].lexicographicallyPrecedes([rhs.id.year,rhs.id.volume,rhs.id.issue])
        }
    }

    var groups: [Group] {
        var seen = Set<Group.Key>()
        let keys = issues.map { Group.Key(year:$0.id.year,volume:$0.id.volume) }
        let grouped = Dictionary(grouping:issues) { Group.Key(year:$0.id.year,volume:$0.id.volume) }
        return keys.filter{seen.insert($0).inserted}.map{Group(id:$0,issues:grouped[$0] ?? [])}
    }

    func neighbors(of book:LibraryBook) -> (previous:Issue?,next:Issue?) {
        guard let index = issues.firstIndex(where:{$0.id == ShelfIssueKey(book.issueMetadata)}) else { return (nil,nil) }
        return (index > 0 ? issues[index-1] : nil, index+1 < issues.count ? issues[index+1] : nil)
    }
}

enum ShelfImportAudit {
    static func warnings(_ drafts:[ShelfImportDraft], chosen:Set<URL>, existing:[LibraryBook]) -> [URL:[String]] {
        func key(_ draft:ShelfImportDraft) -> ShelfIssueKey? {
            ShelfIssueKey((draft.periodical,draft.year,draft.volume,draft.issue))
        }
        let selected = drafts.filter{chosen.contains($0.id)}
        let selectedKeys = Dictionary(grouping:selected,by:key)
        let existingKeys = Dictionary(grouping:existing,by:{ShelfIssueKey($0.issueMetadata)})
        var result: [URL:[String]] = [:]
        for draft in selected {
            var messages: [String] = []
            if !ShelfText.key(draft.periodical).isEmpty && ShelfText.key(draft.year).isEmpty { messages.append("缺少年份") }
            if let identity = key(draft),
               (selectedKeys[identity]?.count ?? 0) > 1 ||
               existingKeys[identity]?.contains(where:{ ReadingBookIdentity.key($0.path) != ReadingBookIdentity.key(draft.url.path) }) == true {
                messages.append("同一期已有其他文件")
            }
            let inferred = ShelfText.infer(draft.url.deletingPathExtension().lastPathComponent)
            let fields = [(draft.periodical,inferred.periodical,"刊名",Character(" ")),
                          (draft.year,inferred.year,"年份",Character("年")),
                          (draft.volume,inferred.volume,"卷号",Character("卷")),
                          (draft.issue,inferred.issue,"期号",Character("期"))]
            let conflicts = fields.compactMap { current,original,label,suffix -> String? in
                let a = ShelfIssueKey.component(current,suffix:suffix), b = ShelfIssueKey.component(original,suffix:suffix)
                return !a.isEmpty && !b.isEmpty && a != b ? label : nil
            }
            if !conflicts.isEmpty { messages.append("与文件名不一致：" + conflicts.joined(separator:"、")) }
            if !messages.isEmpty { result[draft.url] = messages }
        }
        return result
    }
}

enum ShelfChecklist {
    enum Format: String, CaseIterable { case csv, md }
    static func render(_ format:Format,books:[LibraryBook],progress:[String:ReadingProgress],summaries:[String:ShelfRecordSummary]) -> String {
        let headings = ["书名","刊名","年份","卷","期","版本","阅读状态","摘录数","原文链接"]
        let rows = books.map { book in
            let issue = book.issueMetadata
            let link = (try? ReadingShortcut(path:book.path,title:book.title,position:ViewPosition(selection:0)).link().absoluteString) ?? ""
            let count = summaries[ReadingBookIdentity.key(book.path)]?.counts["摘录",default:0] ?? 0
            return [book.title,issue.periodical,issue.year,issue.volume,issue.issue,book.shelfEdition?.rawValue ?? "",
                    book.shelfStatus(progress[book.path]).rawValue,String(count),link]
        }
        switch format {
        case .csv:
            func quote(_ field:String) -> String {
                let first = field.trimmingCharacters(in:.whitespacesAndNewlines).first
                let safe = first.map{"=+-@".contains($0)} == true ? "'"+field : field
                return "\"" + safe.replacingOccurrences(of:"\"",with:"\"\"") + "\""
            }
            return ([headings]+rows).map{$0.map(quote).joined(separator:",")}.joined(separator:"\r\n")+"\r\n"
        case .md:
            func row(_ fields:[String]) -> String {
                "| " + fields.map {
                    $0.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"|",with:"\\|")
                        .components(separatedBy:.newlines).joined(separator:" ")
                }.joined(separator:" | ") + " |"
            }
            let linked = rows.map { row in
                var fields = row
                if let link = fields.last, !link.isEmpty { fields[fields.count-1] = "[打开原文](<\(link)>)" }
                return fields
            }
            return ([row(headings),row(Array(repeating:"---",count:headings.count))]+linked.map(row)).joined(separator:"\n")+"\n"
        }
    }
}
