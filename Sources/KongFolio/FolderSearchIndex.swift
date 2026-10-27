import Foundation
import SQLite3

struct FolderSearchPage: Codable {
    var index: Int
    var text: String
    var label: String?
    var glyphs: [OrderedText.Glyph]?
    var category: String? = nil
    var sourceRect: CGRect? = nil
}

/// A disposable local cache. Each document replaces its old rows in one transaction; interrupted documents never look complete.
final class FolderSearchIndex {
    private var db: OpaquePointer?
    private var transaction = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            let error=failure();sqlite3_close(db);db=nil;throw error
        }
        sqlite3_busy_timeout(db,1000)
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            try exec("CREATE TABLE IF NOT EXISTS documents(path TEXT PRIMARY KEY,digest TEXT NOT NULL,version INTEGER NOT NULL,pages INTEGER NOT NULL,textPages INTEGER NOT NULL);")
            try exec("CREATE TABLE IF NOT EXISTS pages(path TEXT NOT NULL,position INTEGER NOT NULL,payload BLOB NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(path,position));")
        } catch { sqlite3_close(db);db=nil;throw error }
    }
    deinit { rollback();sqlite3_close(db) }
    private func failure() -> FolioError { FolioError(message:"搜索索引："+(db.map { String(cString:sqlite3_errmsg($0)) } ?? "无法打开")) }
    private func exec(_ sql:String) throws { guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw failure() } }
    private func statement(_ sql:String) throws -> OpaquePointer {
        var result:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&result,nil)==SQLITE_OK,let result else { throw failure() };return result
    }
    private func bind(_ value:String,to statement:OpaquePointer,at index:Int32) throws {
        guard sqlite3_bind_text(statement,index,value,-1,Self.transient)==SQLITE_OK else { throw failure() }
    }
    private func step(_ statement:OpaquePointer) throws { guard sqlite3_step(statement)==SQLITE_DONE else { throw failure() } }
    /// Callback data is private to this document; callers discard it if the cache is damaged and re-extract the PDF.
    func read(path:String,digest:String,visit:(FolderSearchPage)throws->Void) throws -> Bool {
        let header=try statement("SELECT pages FROM documents WHERE path=? AND digest=? AND version=1")
        defer { sqlite3_finalize(header) }
        try bind(path,to:header,at:1);try bind(digest,to:header,at:2)
        let status=sqlite3_step(header)
        if status==SQLITE_DONE { return false }
        guard status==SQLITE_ROW else { throw failure() }
        let expected=Int(sqlite3_column_int64(header,0))
        let rows=try statement("SELECT position,payload,digest FROM pages WHERE path=? ORDER BY position")
        defer { sqlite3_finalize(rows) }
        try bind(path,to:rows,at:1)
        var count=0
        while true {
            try Task.checkCancellation()
            let state=sqlite3_step(rows)
            if state==SQLITE_DONE { break }
            guard state==SQLITE_ROW,Int(sqlite3_column_int64(rows,0))==count,
                  let pointer=sqlite3_column_blob(rows,1),let checksum=sqlite3_column_text(rows,2) else { throw FolioError(message:"搜索页缓存不完整") }
            let data=Data(bytes:pointer,count:Int(sqlite3_column_bytes(rows,1)))
            guard OCRPageCache.digest(data)==String(cString:checksum) else { throw FolioError(message:"搜索页缓存校验失败") }
            let page=try JSONDecoder().decode(FolderSearchPage.self,from:data)
            guard page.index==count else { throw FolioError(message:"搜索页缓存页码不符") }
            try visit(page);count+=1
        }
        guard count==expected,expected>0 else { throw FolioError(message:"搜索页缓存缺失") }
        return true
    }
    func begin(path:String,digest:String,pages:Int) throws {
        try exec("BEGIN IMMEDIATE");transaction=true
        let remove=try statement("DELETE FROM pages WHERE path=?");defer { sqlite3_finalize(remove) }
        try bind(path,to:remove,at:1);try step(remove)
        let header=try statement("INSERT OR REPLACE INTO documents(path,digest,version,pages,textPages) VALUES(?,?,1,?,0)")
        defer { sqlite3_finalize(header) }
        try bind(path,to:header,at:1);try bind(digest,to:header,at:2)
        guard sqlite3_bind_int64(header,3,Int64(pages))==SQLITE_OK else { throw failure() };try step(header)
    }
    func write(_ page:FolderSearchPage,path:String) throws {
        let payload=try JSONEncoder().encode(page)
        guard payload.count<=Int32.max else { throw FolioError(message:"这一页文字过多，跳过索引缓存") }
        let row=try statement("INSERT INTO pages(path,position,payload,digest) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(row) }
        try bind(path,to:row,at:1)
        guard sqlite3_bind_int64(row,2,Int64(page.index))==SQLITE_OK else { throw failure() }
        let status=payload.withUnsafeBytes { sqlite3_bind_blob(row,3,$0.baseAddress,Int32($0.count),Self.transient) }
        guard status==SQLITE_OK else { throw failure() }
        try bind(OCRPageCache.digest(payload),to:row,at:4);try step(row)
    }
    func commit(path:String,textPages:Int) throws {
        let row=try statement("UPDATE documents SET textPages=? WHERE path=?");defer { sqlite3_finalize(row) }
        guard sqlite3_bind_int64(row,1,Int64(textPages))==SQLITE_OK else { throw failure() }
        try bind(path,to:row,at:2);try step(row);try exec("COMMIT");transaction=false
    }
    func rollback() { if transaction { try? exec("ROLLBACK");transaction=false } }
}
