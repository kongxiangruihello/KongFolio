import Foundation

/// File bookmarks survive a move; the logical ID survives a changed PDF or atomic save.
struct ReadingDocumentIdentity053:Codable {
    var id=UUID()
    var paths:[String]
    var resource:String?
    var digest:String?
    var bookmark:Data?
}
@MainActor final class ReadingDocumentRegistry053 {
    private static var registries:[String:ReadingDocumentRegistry053]=[:]
    static func shared(_ storage:URL)->ReadingDocumentRegistry053 {
        if let value=registries[storage.path] { return value };let value=ReadingDocumentRegistry053(storage);registries[storage.path]=value;return value
    }
    private let file:URL
    private var entries:[ReadingDocumentIdentity053]
    init(_ storage:URL) { file=storage.appendingPathComponent("DocumentIdentity053.json");entries=(try? Data(contentsOf:file)).flatMap{try? JSONDecoder().decode([ReadingDocumentIdentity053].self,from:$0)} ?? [] }
    func identity(_ path:String,digest:String?)->ReadingDocumentIdentity053 {
        let url=URL(fileURLWithPath:path),canonical=ReadingBookIdentity.key(path)
        let resource=(try? url.resourceValues(forKeys:[.fileResourceIdentifierKey]))?.fileResourceIdentifier.map{String(describing:$0)}
        let i=entries.firstIndex{ entry in
            entry.paths.contains(canonical) || (resource != nil && entry.resource==resource) || (digest != nil && entry.digest==digest && !entry.paths.contains(where:{FileManager.default.fileExists(atPath:$0)}))
        }
        var value=i.map{entries[$0]} ?? ReadingDocumentIdentity053(paths:[canonical])
        let old=value
        if !value.paths.contains(canonical) { value.paths.append(canonical) }
        value.resource=resource;value.digest=digest
        if i==nil || old.paths != value.paths { value.bookmark=try? url.bookmarkData(options:.suitableForBookmarkFile,includingResourceValuesForKeys:nil,relativeTo:nil) }
        if let i { entries[i]=value } else { entries.append(value) }
        if i==nil || old.paths != value.paths || old.digest != value.digest {
            let entries=entries,file=file
            Task { do { try await ReadingIdentityWriter053.shared.write(entries,to:file) } catch { /* The citation still contains its path and fingerprint. */ } }
        }
        return value
    }
    func resolve(_ path:String)->String {
        guard !FileManager.default.fileExists(atPath:path),let entry=entries.first(where:{$0.paths.contains(ReadingBookIdentity.key(path))}) else { return path }
        for alias in entry.paths.reversed() where FileManager.default.fileExists(atPath:alias) { return alias }
        if let data=entry.bookmark { var stale=false;if let url=try? URL(resolvingBookmarkData:data,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale),FileManager.default.fileExists(atPath:url.path) { return url.path } }
        return path
    }
}
actor ReadingIdentityWriter053 {
    static let shared=ReadingIdentityWriter053()
    func write(_ entries:[ReadingDocumentIdentity053],to file:URL)throws { try JSONEncoder().encode(entries).write(to:file,options:.atomic) }
}
extension ReadingJournal {
    func adoptDocument053(_ identity:ReadingDocumentIdentity053,path:String) {
        let old=state
        var next=old
        for i in next.records.indices { for j in next.records[i].citations.indices {
            var c=next.records[i].citations[j]
            guard c.tracking?.documentID==identity.id || identity.paths.contains(ReadingBookIdentity.key(c.source.path)) else { continue }
            if c.tracking==nil { c.tracking=ReadingSourceIdentity053(documentID:identity.id,capturedPage:c.source.page,pageFingerprint:nil,capturedPageLabel:c.source.pageLabel) }
            else { c.tracking?.documentID=identity.id }
            c.source.path=path;c.source.fileName=URL(fileURLWithPath:path).lastPathComponent
            next.records[i].citations[j]=c
        } }
        if next != old { change{$0=next} }
    }
    func remapSources053(path:String,order:[Int]) {
        guard !unreadable else { return }
        let before=state
        change { s in
            for i in s.records.indices {
                var changed=false
                for j in s.records[i].citations.indices where ReadingBookIdentity.key(s.records[i].citations[j].source.path)==ReadingBookIdentity.key(path) {
                    var c=s.records[i].citations[j]
                    if c.tracking==nil { c.tracking=ReadingSourceIdentity053(documentID:ReadingJournal.stablePDFRecordID(path),capturedPage:c.source.page,pageFingerprint:c.source.fingerprint,capturedPageLabel:c.source.pageLabel) }
                    if let next=order.firstIndex(of:c.source.page) { c.source.page=next;c.source.invalidPage053=nil;c.tracking?.needsReview=nil }
                    else { c.source.invalidPage053=true;c.tracking?.needsReview=true }
                    if c != s.records[i].citations[j] { s.records[i].citations[j]=c;changed=true }
                }
                if changed { s.records[i].modified=Date() }
            }
        }
        if before != state { finishBulk(before,"页面变动后的出处校准") }
    }
}
