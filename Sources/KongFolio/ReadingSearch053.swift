import Foundation
import SQLite3

struct ReadingLibraryOptions053:Codable,Hashable {
    enum Scope:String,Codable,CaseIterable { case all="全部内容",mine="我的笔记",quote="原文摘录",comment="PDF 评论" }
    enum Sort:String,Codable,CaseIterable { case relevance="相关程度",created="记录时间",modified="修改时间",source="文献页码",title="标题" }
    var scope=Scope.all
    var exact=false
    var author=""
    var book=""
    var firstPage:Int? = nil
    var lastPage:Int? = nil
    var after:Date? = nil
    var before:Date? = nil
    var dateIsModified=false
    var review:ReadingRecordExtras053.Review? = nil
    var meaning=""
    var chapter=""
    var groupChapters=false
    var sort=Sort.created
    var showSource=true
    var showKind=true
    var showCreated=true
    var showModified=false
    var titleWidth=220.0
    var sourceWidth=190.0
    var table=false
    static func load(_ defaults:UserDefaults)->Self { defaults.data(forKey:"Reading.options053").flatMap{try? JSONDecoder().decode(Self.self,from:$0)} ?? Self() }
    func save(_ defaults:UserDefaults) { if let data=try? JSONEncoder().encode(self) { defaults.set(data,forKey:"Reading.options053") } }
}
struct ReadingSearchExpression053 {
    struct Term { var text:String;var negative:Bool }
    var groups:[[Term]]
    init(_ text:String) {
        let regex=try! NSRegularExpression(pattern:"-?\"[^\"]*\"|[^\\s]+")
        var groups:[[Term]]=[[]]
        for match in regex.matches(in:text,range:NSRange(location:0,length:text.utf16.count)) {
            var token=(text as NSString).substring(with:match.range)
            if ["OR","或","或者"].contains(token) { groups.append([]);continue }
            if ["AND","且","并且"].contains(token) { continue }
            let negative=token.hasPrefix("-");if negative { token.removeFirst() }
            if token.hasPrefix("\""),token.hasSuffix("\"") { token=String(token.dropFirst().dropLast()) }
            if !token.isEmpty { groups[groups.count-1].append(Term(text:token,negative:negative)) }
        }
        self.groups=groups.filter{!$0.isEmpty}
    }
    static func normalized(_ text:String,exact:Bool=false)->String {
        if exact { return text }
        // U+FA11 has no Unicode decomposition despite its compatibility-block placement.
        let folded=AnnotationFilter.folded(text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:"﨑",with:"崎"))
        // OCR spaces between Han glyphs should not prevent an ordinary Chinese phrase search.
        let regex=try! NSRegularExpression(pattern:"(?<=[\\p{Han}])\\s+(?=[\\p{Han}])")
        return regex.stringByReplacingMatches(in:folded,range:NSRange(location:0,length:folded.utf16.count),withTemplate:"")
    }
    func matches(_ text:String,exact:Bool)->Bool {
        guard !groups.isEmpty else { return true }
        let value=Self.normalized(text,exact:exact)
        return groups.contains { group in group.allSatisfy { term in let found=value.contains(Self.normalized(term.text,exact:exact));return term.negative ? !found:found } }
    }
    var firstPositive:String { groups.flatMap{$0}.first(where:{!$0.negative})?.text ?? "" }
    static func grams(_ text:String)->Set<String> {
        let chars=Array(normalized(text));guard chars.count>=2 else { return [] }
        // Hex tokens avoid tokenizer differences for punctuation, scripts and compatibility forms.
        return Set((0..<(chars.count-1)).map{ n in "g"+String(String(chars[n...n+1]).utf8.map{String(format:"%02x",$0)}.joined()) })
    }
    var indexQuery:String? {
        guard !groups.isEmpty else { return nil }
        var alternatives:[String]=[]
        for group in groups {
            let terms=group.filter{!$0.negative};guard !terms.isEmpty else { return nil }
            var conjunctions:[String]=[]
            for term in terms {
                let grams=Self.grams(term.text);guard !grams.isEmpty else { return nil }
                conjunctions += grams.sorted().prefix(32).map{"\""+$0+"\""}
            }
            alternatives.append("("+conjunctions.joined(separator:" AND ")+")")
        }
        return alternatives.joined(separator:" OR ")
    }
}
extension ReadingLibraryItem {
    func searchText053(_ scope:ReadingLibraryOptions053.Scope)->String {
        switch self {
        case .record(let r):
            switch scope {
            case .mine:return r.note
            case .quote:return r.quote
            case .comment:return r.pdfOrigin?.contents ?? ""
            case .all:return [r.title,r.quote,r.note,r.pdfOrigin?.contents ?? "",r.tags.joined(separator:" "),r.citations053.map{[$0.title,$0.author,$0.edition ?? "",$0.publication?.summary ?? "",$0.source.pageDescription].joined(separator:" ")}.joined(separator:"\n"),(r.extras?.quotations ?? []).map(\.text).joined(separator:"\n")].joined(separator:"\n")
            }
        case .essay(let e):
            switch scope {
            case .mine:return e.blocks.map(\.text).joined(separator:"\n")
            case .quote:return e.blocks.compactMap{$0.record?.quote}.joined(separator:"\n")
            case .comment:return e.blocks.compactMap{$0.record?.pdfOrigin?.contents}.joined(separator:"\n")
            case .all:return ([e.title,e.tags.joined(separator:" "),(e.extras?.quotations ?? []).map{$0.text+" "+$0.citations.map{ReadingExportOrdering.citation($0)}.joined(separator:" ")}.joined(separator:"\n")]+e.blocks.flatMap{[$0.text,$0.record.map{ReadingLibraryItem.record($0).searchText053(.all)} ?? ""]}).joined(separator:"\n")
            }
        }
    }
    func filtered053(_ o:ReadingLibraryOptions053)->Bool {
        let date=o.dateIsModified ? modified053:created
        if let after=o.after,date<after { return false };if let before=o.before,date>=Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:before))! { return false }
        if let review=o.review,(extras053.review ?? .unreviewed) != review { return false }
        if !o.meaning.isEmpty,extras053.colorMeaning != o.meaning { return false }
        if !o.chapter.isEmpty,chapter053 != o.chapter { return false }
        let constrained = !o.author.isEmpty || !o.book.isEmpty || o.firstPage != nil || o.lastPage != nil
        guard constrained else { return true }
        return citations053.contains { c in
            if !o.author.isEmpty,!ReadingSearchExpression053.normalized(c.author).contains(ReadingSearchExpression053.normalized(o.author)) { return false }
            if !o.book.isEmpty,!ReadingSearchExpression053.normalized(c.title+" "+(c.publication?.summary ?? "")).contains(ReadingSearchExpression053.normalized(o.book)) { return false }
            if let first=o.firstPage,c.source.page+1<first { return false };if let last=o.lastPage,c.source.page+1>last { return false };return true
        }
    }
}

/// A derived, disposable index: the journal remains the authoritative source. Every index hit
/// is checked against the real text, including negatives, scope and exact glyph mode.
actor ReadingSearchIndex053 {
    static let shared=ReadingSearchIndex053()
    private var db:OpaquePointer?
    private var location=""
    private var revision:Int?
    private var signatures:[String:String]=[:]
    private(set) var lastError:String?
    private var transient:sqlite3_destructor_type { unsafeBitCast(-1,to:sqlite3_destructor_type.self) }
    func close() { if let db { sqlite3_close_v2(db) };db=nil;revision=nil;signatures=[:] }
    private func execute(_ sql:String)throws { guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw FolioError(message:"检索索引暂不可用") } }
    private func open(_ folder:URL)throws {
        let path=folder.appendingPathComponent("Search053.sqlite").path
        guard location != path || db==nil else { return };close();location=path
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        guard sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else { close();throw FolioError(message:"无法创建检索索引") }
        sqlite3_busy_timeout(db,1000)
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS records053 USING fts5(id UNINDEXED, grams, tokenize='unicode61')")
        try execute("CREATE TABLE IF NOT EXISTS signatures053(id TEXT PRIMARY KEY,digest TEXT NOT NULL)")
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT id,digest FROM signatures053",-1,&statement,nil)==SQLITE_OK else { throw FolioError(message:"无法读取索引版本") };defer{sqlite3_finalize(statement)}
        while sqlite3_step(statement)==SQLITE_ROW { if let id=sqlite3_column_text(statement,0),let digest=sqlite3_column_text(statement,1) { signatures[String(cString:id)]=String(cString:digest) } }
        if signatures.isEmpty { try execute("DELETE FROM records053") }
    }
    func candidates(_ items:[ReadingLibraryItem],revision:Int,folder:URL,query:ReadingSearchExpression053,exact:Bool)->Set<String>? {
        guard !exact,let match=query.indexQuery else { return nil }
        do {
            try open(folder)
            if self.revision != revision {
                var next:[String:String]=[:];try execute("BEGIN IMMEDIATE")
                do {
                    let known=Set(items.map(\.key))
                    for old in signatures.keys where !known.contains(old) { try remove(old) }
                    for item in items {
                        try Task.checkCancellation()
                        let text=item.searchText053(.all),hash=OCRPageCache.digest(Data(text.utf8));next[item.key]=hash
                        guard signatures[item.key] != hash else { continue }
                        try remove(item.key)
                        var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,"INSERT INTO records053(id,grams) VALUES(?,?)",-1,&statement,nil)==SQLITE_OK else { throw FolioError(message:"无法更新索引") };defer{sqlite3_finalize(statement)}
                        let grams=ReadingSearchExpression053.grams(text).sorted().joined(separator:" ")
                        sqlite3_bind_text(statement,1,item.key,-1,transient);sqlite3_bind_text(statement,2,grams,-1,transient)
                        guard sqlite3_step(statement)==SQLITE_DONE else { throw FolioError(message:"无法写入索引") }
                        try signature(item.key,digest:hash)
                    }
                    try execute("COMMIT");signatures=next;self.revision=revision
                } catch { try? execute("ROLLBACK");throw error }
            }
            var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT id FROM records053 WHERE records053 MATCH ?",-1,&statement,nil)==SQLITE_OK else { throw FolioError(message:"无法检索索引") };defer{sqlite3_finalize(statement)}
            sqlite3_bind_text(statement,1,match,-1,transient)
            var keys=Set<String>(),code=sqlite3_step(statement)
            while code==SQLITE_ROW { if let value=sqlite3_column_text(statement,0) { keys.insert(String(cString:value)) };code=sqlite3_step(statement) }
            guard code==SQLITE_DONE else { throw FolioError(message:"索引检索未完成") };lastError=nil;return keys
        } catch { lastError=error.localizedDescription;close();return nil }
    }
    private func remove(_ id:String)throws {
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,"DELETE FROM records053 WHERE id=?",-1,&statement,nil)==SQLITE_OK else { throw FolioError(message:"无法更新索引") };defer{sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,id,-1,transient);guard sqlite3_step(statement)==SQLITE_DONE else { throw FolioError(message:"无法更新索引") }
        var signature:OpaquePointer?;guard sqlite3_prepare_v2(db,"DELETE FROM signatures053 WHERE id=?",-1,&signature,nil)==SQLITE_OK else { throw FolioError(message:"无法更新索引摘要") };defer{sqlite3_finalize(signature)}
        sqlite3_bind_text(signature,1,id,-1,transient);guard sqlite3_step(signature)==SQLITE_DONE else { throw FolioError(message:"无法更新索引摘要") }
    }
    private func signature(_ id:String,digest:String)throws {
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO signatures053(id,digest) VALUES(?,?)",-1,&statement,nil)==SQLITE_OK else { throw FolioError(message:"无法保存索引摘要") };defer{sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,id,-1,transient);sqlite3_bind_text(statement,2,digest,-1,transient);guard sqlite3_step(statement)==SQLITE_DONE else { throw FolioError(message:"无法保存索引摘要") }
    }
}
