import Foundation

extension Workspace {
    var readingPageIDs053:[Int:String] {
        get { Dictionary(uniqueKeysWithValues:pageMeta.enumerated().compactMap{ i,m in m.readingID053.map{(i,$0)} }) }
        set { alignMeta();for i in pageMeta.indices { pageMeta[i].readingID053=newValue[i] } }
    }
    func pageIdentity053(_ i:Int)->String? {
        alignMeta();guard pageMeta.indices.contains(i) else { return nil }
        if let value=pageMeta[i].readingID053 { return value }
        let value=UUID().uuidString;pageMeta[i].readingID053=value;return value
    }
    func preparePageIdentities053() {
        guard let path=readingJournalPath,let journal=store?.journal else { return }
        for i in 0..<count { _=pageIdentity053(i) }
        let ids=readingPageIDs053,old=journal.state
        var next=old
        for i in next.records.indices {
            for j in next.records[i].citations.indices where ReadingBookIdentity.key(next.records[i].citations[j].source.path)==ReadingBookIdentity.key(path) {
                var c=next.records[i].citations[j]
                guard c.source.invalidPage053 != true,let id=ids[c.source.page] else { continue }
                if c.tracking==nil { c.tracking=ReadingSourceIdentity053(documentID:ReadingJournal.stablePDFRecordID(path),capturedPage:c.source.page,pageFingerprint:id,capturedPageLabel:c.source.pageLabel) }
                else if c.tracking?.pageFingerprint==nil || c.tracking?.pageFingerprint==c.source.fingerprint { c.tracking?.pageFingerprint=id }
                next.records[i].citations[j]=c
            }
        }
        if next != old { journal.change{$0=next} }
    }
    func reconcilePageIdentities053() {
        guard let path=readingJournalPath,let journal=store?.journal else { return }
        let ids=readingPageIDs053,old=journal.state
        var next=old
        for i in next.records.indices {
            for j in next.records[i].citations.indices where ReadingBookIdentity.key(next.records[i].citations[j].source.path)==ReadingBookIdentity.key(path) {
                var c=next.records[i].citations[j]
                guard let fingerprint=c.tracking?.pageFingerprint else { continue }
                if let index=ids.keys.sorted().first(where:{ids[$0]==fingerprint}) { c.source.page=index;c.source.invalidPage053=nil;c.tracking?.needsReview=nil }
                else { c.source.invalidPage053=true;c.tracking?.needsReview=true }
                next.records[i].citations[j]=c
            }
        }
        if next != old { journal.change{$0=next} }
    }
}
