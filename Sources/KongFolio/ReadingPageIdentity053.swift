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
        guard let path = readingJournalPath, let journal = store?.journal else { return }
        for i in 0..<count { _ = pageIdentity053(i) }
        let ids = readingPageIDs053, key = ReadingBookIdentity.key(path)
        journal.updateSourceLocations { citation in
            guard ReadingBookIdentity.key(citation.source.path) == key, citation.source.invalidPage053 != true,
                  let id = ids[citation.source.page] else { return }
            if citation.tracking == nil {
                citation.tracking = ReadingSourceIdentity053(documentID:ReadingJournal.stablePDFRecordID(path),capturedPage:citation.source.page,
                                                              pageFingerprint:id,capturedPageLabel:citation.source.pageLabel)
            } else if citation.tracking?.pageFingerprint == nil || citation.tracking?.pageFingerprint == citation.source.fingerprint {
                citation.tracking?.pageFingerprint = id
            }
        }
    }

    func reconcilePageIdentities053() {
        guard let path = readingJournalPath, let journal = store?.journal else { return }
        let ids = readingPageIDs053
        let positions = Dictionary(ids.map { ($0.value,$0.key) },uniquingKeysWith:min)
        let key = ReadingBookIdentity.key(path)
        journal.updateSourceLocations { citation in
            guard ReadingBookIdentity.key(citation.source.path) == key, let fingerprint = citation.tracking?.pageFingerprint else { return }
            if let page = positions[fingerprint] {
                citation.source.page = page
                citation.source.invalidPage053 = nil
                citation.tracking?.needsReview = nil
            } else {
                citation.source.invalidPage053 = true
                citation.tracking?.needsReview = true
            }
        }
    }
}
