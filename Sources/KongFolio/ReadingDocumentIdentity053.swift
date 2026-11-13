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
    func resolve(_ path:String, documentID:UUID? = nil)->String {
        guard !FileManager.default.fileExists(atPath:path),
              let entry = entries.first(where:{ $0.id == documentID || $0.paths.contains(ReadingBookIdentity.key(path)) }) else { return path }
        for alias in entry.paths.reversed() where FileManager.default.fileExists(atPath:alias) { return alias }
        if let data=entry.bookmark { var stale=false;if let url=try? URL(resolvingBookmarkData:data,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale),FileManager.default.fileExists(atPath:url.path) { return url.path } }
        return path
    }
}
actor ReadingIdentityWriter053 {
    static let shared=ReadingIdentityWriter053()
    func write(_ entries:[ReadingDocumentIdentity053],to file:URL)throws { try JSONEncoder().encode(entries).write(to:file,options:.atomic) }
}
extension ReadingRecordExtras053 {
    mutating func updateSourceLocations(_ update: (inout ReadingCitation) -> Void) {
        if var regions {
            for index in regions.indices { update(&regions[index].citation) }
            self.regions = regions
        }
        if var quotations {
            for index in quotations.indices {
                for source in quotations[index].citations.indices { update(&quotations[index].citations[source]) }
            }
            self.quotations = quotations
        }
    }
}

extension ReadingJournal {
    func updateSourceLocations(_ update: (inout ReadingCitation) -> Void) {
        guard !unreadable else { return }
        func updateRecord(_ record: inout ReadingRecord) {
            for index in record.citations.indices { update(&record.citations[index]) }
            if var links = record.inlineNoteCitations {
                for index in links.indices { update(&links[index].citation) }
                record.inlineNoteCitations = links
            }
            record.extras?.updateSourceLocations(update)
        }
        var next = state
        for index in next.records.indices { updateRecord(&next.records[index]) }
        for index in next.essays.indices {
            next.essays[index].extras?.updateSourceLocations(update)
            for block in next.essays[index].blocks.indices {
                if var record = next.essays[index].blocks[block].record {
                    updateRecord(&record)
                    next.essays[index].blocks[block].record = record
                }
            }
        }
        if next != state { change { $0 = next } }
    }

    func adoptDocument053(_ identity: ReadingDocumentIdentity053, path: String) {
        updateSourceLocations { citation in
            guard citation.tracking?.documentID == identity.id || identity.paths.contains(ReadingBookIdentity.key(citation.source.path)) else { return }
            if citation.tracking == nil {
                citation.tracking = ReadingSourceIdentity053(documentID:identity.id,capturedPage:citation.source.page,pageFingerprint:nil,capturedPageLabel:citation.source.pageLabel)
            } else { citation.tracking?.documentID = identity.id }
            citation.source.path = path
            citation.source.fileName = URL(fileURLWithPath:path).lastPathComponent
        }
    }

    func remapSources053(path: String, order: [Int]) {
        let before = state
        let key = ReadingBookIdentity.key(path)
        let newPositions = Dictionary(order.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
        updateSourceLocations { citation in
            guard ReadingBookIdentity.key(citation.source.path) == key, citation.source.invalidPage053 != true else { return }
            if citation.tracking == nil {
                citation.tracking = ReadingSourceIdentity053(documentID:Self.stablePDFRecordID(path),capturedPage:citation.source.page,
                                                              pageFingerprint:citation.source.fingerprint,capturedPageLabel:citation.source.pageLabel)
            }
            if let page = newPositions[citation.source.page] {
                citation.source.page = page
                citation.source.invalidPage053 = nil
                citation.tracking?.needsReview = nil
            } else {
                citation.source.invalidPage053 = true
                citation.tracking?.needsReview = true
            }
        }
        if before != state { finishBulk(before,"页面变动后的出处校准") }
    }
}
