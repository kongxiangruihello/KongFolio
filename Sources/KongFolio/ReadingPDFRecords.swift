import Foundation
import PDFKit

struct ReadingPDFOrigin:Codable,Equatable {
    var annotationID:String
    var type:String
    var contents:String
    var author:String?
    var originalCreated:Date?
    var originalCreatedRaw:String? = nil
    var originalModified:Date?
    var missingSince:Date?
    var color053:String? = nil
}
enum ReadingPDFCapture {
    static let createdKey = PDFAnnotationKey(rawValue:"KFReadingCreated")
    static func stampAdded(_ annotation:PDFAnnotation,now:Date = Date()) {
        annotation.setValue(ISO8601DateFormatter().string(from:now),forAnnotationKey:createdKey)
        annotation.modificationDate = now
    }
    static func originalCreated(_ a:PDFAnnotation)->Date? {
        if let value = a.value(forAnnotationKey:createdKey) as? String { return ISO8601DateFormatter().date(from:value) }
        if let value = a.value(forAnnotationKey:PDFAnnotationKey(rawValue:"CreationDate")) as? Date { return value }
        guard let raw = a.value(forAnnotationKey:PDFAnnotationKey(rawValue:"CreationDate")) as? String else { return nil }
        if let value = ISO8601DateFormatter().date(from:raw) { return value }
        let text = raw.hasPrefix("D:") ? String(raw.dropFirst(2)) : raw
        guard text.count >= 14 else { return nil }
        let date = DateFormatter();date.locale = Locale(identifier:"en_US_POSIX");date.dateFormat = "yyyyMMddHHmmss";date.timeZone = TimeZone(secondsFromGMT:0)
        // Missing time zones are not guessed as the current local zone.
        let tail = String(text.dropFirst(14)).replacingOccurrences(of:"'",with:"")
        guard tail == "Z" || tail.count == 5 else { return nil }
        if tail != "Z" {
            guard tail.count == 5,let h=Int(tail.dropFirst().prefix(2)),let m=Int(tail.suffix(2)),h<=23,m<=59,tail.first == "+" || tail.first == "-" else { return nil }
            date.timeZone = TimeZone(secondsFromGMT:(tail.first == "-" ? -1 : 1)*(h*3600+m*60))
        }
        return date.date(from:String(text.prefix(14)))
    }
    static func identity(_ a:PDFAnnotation,on page:PDFPage,index:Int)->String {
        if let id = a.value(forAnnotationKey:AnnotationIdentity.key) as? String,!id.isEmpty { return id }
        if let id = a.value(forAnnotationKey:PDFAnnotationKey(rawValue:"NM")) as? String,!id.isEmpty { return "pdf:"+id }
        let b = a.bounds,type = a.type ?? "Unknown"
        let preceding = page.annotations.prefix { $0 !== a }.filter{$0.type == a.type && $0.bounds == b}.count
        return "legacy:"+String(index)+":"+type+":"+[b.minX,b.minY,b.width,b.height].map{String(format:"%.6f",Double($0))}.joined(separator:",")+":"+String(preceding)
    }
    static func record(_ a:PDFAnnotation,page:PDFPage,index:Int,source:ReadingCitation)->ReadingRecord? {
        guard !["Link","Widget","Popup"].contains(a.type ?? "") else { return nil }
        let type = a.type ?? "Unknown",id = identity(a,on:page,index:index)
        let markup = ["Highlight","Underline","StrikeOut"].contains(type)
        let bounds = a.bounds
        let valid = [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy{$0.isFinite} && bounds.width >= 0 && bounds.height >= 0
        let quote = a.value(forAnnotationKey:ReadingServices.quoteKey) as? String ?? (markup && valid ? page.selection(for:bounds)?.string ?? "" : "")
        let origin = ReadingPDFOrigin(annotationID:id,type:ReadingServices.kindName(for:type),contents:a.contents ?? "",author:a.userName,originalCreated:originalCreated(a),originalCreatedRaw:a.value(forAnnotationKey:PDFAnnotationKey(rawValue:"CreationDate")) as? String,originalModified:a.modificationDate,color053:ReadingColorSemantics053.code(a.color))
        var citation = source;citation.source.rects = valid ? [bounds] : [];citation.source.anchor = quote.isEmpty ? nil : String(quote.prefix(80))
        return ReadingRecord(id:ReadingJournal.stablePDFRecordID(ReadingBookIdentity.key(source.source.path)+":"+id),kind:["Text","FreeText"].contains(type) ? .comment : .annotation,quote:quote,citations:[citation],pdfOrigin:origin)
    }
}
@MainActor extension Workspace {
    func prepareReadingAnnotationIdentity(_ annotation:PDFAnnotation,on page:PDFPage,index:Int) {
        if let id=annotation.value(forAnnotationKey:AnnotationIdentity.key) as? String,!id.isEmpty { return }
        annotation.setValue(ReadingPDFCapture.identity(annotation,on:page,index:index),forAnnotationKey:AnnotationIdentity.key)
    }
    func captureReadingAnnotationPages(_ pages:Set<Int>) {
        guard let path = readingJournalPath,!path.isEmpty,let journal = store?.journal,!journal.unreadable else { return }
        let records = pages.sorted().flatMap { index -> [ReadingRecord] in
            guard let page = document.page(at:index) else { return [] }
            let source = readingCitation(page:index,trackVisual:false)
            return page.annotations.compactMap { a in
                guard var record=ReadingPDFCapture.record(a,page:page,index:index,source:source) else { return nil }
                if let bytes=ReadingVisual053.annotation(a),let name=try? journal.stageAsset053(bytes) { record.extras=ReadingRecordExtras053(colorMeaning:ReadingColorSemantics053.meaning(a.color),visualAsset:name) }
                return record
            }
        }
        journal.mergePDFRecords(records,path:path,pages:pages)
    }
    func scheduleReadingAnnotationImport() {
        readingAnnotationTask?.cancel();readingAnnotationTask = nil
        guard let url = sourceURL ?? projectURL,["pdf","kongfolio"].contains(url.pathExtension.lowercased()),let path = readingJournalPath,store != nil,!needsLoad,!dirty else { return }
        let identity=ReadingDocumentRegistry053.shared(storage).identity(path,digest:fileBaseline?.digest)
        store?.journal.adoptDocument053(identity,path:path)
        let token = revision,expected = fileBaseline?.digest,title = bibliography.title.isEmpty ? self.title : bibliography.title,author = bibliography.author,edition = bibliography.edition
        readingAnnotationTask = Task { [weak self] in
            do {
                let records = try await ReadingPDFImportWorker.shared.read(url,path:path,title:title,author:author,edition:edition,expected:expected,assetFolder:self?.store?.journal.folder)
                guard !Task.isCancelled,let self,self.revision == token,self.readingJournalPath == path else { return }
                self.store?.journal.mergePDFRecords(records,path:path,pages:nil)
            } catch {
                guard !Task.isCancelled,let self,self.revision == token,!FolioCancellation.matches(error) else { return }
                self.store?.journal.pdfCaptureMessage = "PDF 标注与评论暂未完整收录："+error.localizedDescription
            }
        }
    }
}
actor ReadingPDFImportWorker {
    static let shared = ReadingPDFImportWorker()
    func read(_ url:URL,path:String,title:String,author:String,edition:String,expected:String?,assetFolder:URL? = nil) throws -> [ReadingRecord] {
        try Task.checkCancellation()
        return try autoreleasepool {
            let scoped = url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
            if let expected,OCRPageCache.digest(bytes) != expected { throw FolioError(message:"原件已变化，请重新打开后收录") }
            let data = url.pathExtension.lowercased() == "kongfolio" ? try ProjectArchive.read(url).pdf : bytes
            guard let doc = PDFDocument(data:data),!doc.isLocked else { throw FolioError(message:"请先解锁 PDF") }
            var result:[ReadingRecord] = []
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at:i) else { continue }
                let citation = ReadingCitation(source:SourceRef(path:path,fileName:url.lastPathComponent,page:i,pageLabel:ReadingServices.pageLabel(page,index:i),fingerprint:expected),title:title,author:author,edition:edition.isEmpty ? nil : edition)
                result += try page.annotations.compactMap { a in
                    guard var record=ReadingPDFCapture.record(a,page:page,index:i,source:citation) else { return nil }
                    if let folder=assetFolder,let bytes=ReadingVisual053.annotation(a) { record.extras=ReadingRecordExtras053(colorMeaning:ReadingColorSemantics053.meaning(a.color),visualAsset:try ReadingVisual053.store(bytes,folder:folder)) }
                    return record
                }
            }
            return result
        }
    }
}
extension ReadingJournal {
    nonisolated static func stablePDFRecordID(_ text:String)->UUID {
        let h = String(OCRPageCache.digest(Data(text.utf8)).prefix(32));let chars = Array(h)
        let s = [String(chars[0..<8]),String(chars[8..<12]),String(chars[12..<16]),String(chars[16..<20]),String(chars[20..<32])].joined(separator:"-")
        return UUID(uuidString:s)!
    }
    func mergePDFRecords(_ records:[ReadingRecord],path:String,pages:Set<Int>?) {
        guard !unreadable else { return }
        let key = ReadingBookIdentity.key(path),now = Date()
        let all = records+state.records.filter{$0.citations.contains{ReadingBookIdentity.key($0.source.path)==key}}
        let duplicates = Set(Dictionary(grouping:all.compactMap { r -> (String,Int)? in guard let id=r.pdfOrigin?.annotationID,let page=r.citations.first?.source.page else { return nil };return (id,page) },by:{$0.0}).filter{Set($0.value.map{$0.1}).count>1}.keys)
        let seen = Set(records.compactMap { r -> String? in guard let id=r.pdfOrigin?.annotationID,let page=r.citations.first?.source.page else { return nil };return id+":"+String(page) })
        var next = state
        func lookupKey(_ origin:ReadingPDFOrigin,_ page:Int)->String { origin.annotationID+(duplicates.contains(origin.annotationID) ? ":page:"+String(page) : "") }
        var indices:[String:Int] = [:]
        for (i,record) in next.records.enumerated() {
            if let origin=record.pdfOrigin,let source=record.citations.first,ReadingBookIdentity.key(source.source.path)==key { indices[lookupKey(origin,source.source.page)] = i }
        }
        for incoming in records {
            guard let origin = incoming.pdfOrigin else { continue }
            let identity = lookupKey(origin,incoming.citations.first?.source.page ?? 0)
            if let i = indices[identity] {
                let old = next.records[i]
                next.records[i].kind = incoming.kind;next.records[i].pdfOrigin = origin;next.records[i].quote = incoming.quote
                if let visual=incoming.extras?.visualAsset { var extras=old.extras ?? ReadingRecordExtras053();extras.visualAsset=visual;if let meaning=incoming.extras?.colorMeaning { extras.colorMeaning=meaning };next.records[i].extras=extras }
                var sources = incoming.citations
                if !sources.isEmpty { sources[0].source.fingerprint = old.citations.first?.source.fingerprint ?? sources[0].source.fingerprint;sources[0].tracking=old.citations.first?.tracking ?? sources[0].tracking;sources[0].publication=old.citations.first?.publication ?? sources[0].publication }
                next.records[i].citations = sources
                if old.pdfOrigin != origin || old.quote != incoming.quote || old.citations != sources { next.records[i].modified = now }
            } else {
                var value = incoming
                if duplicates.contains(origin.annotationID),let page=value.citations.first?.source.page { value.id = Self.stablePDFRecordID(key+":"+origin.annotationID+":"+String(page)) }
                indices[identity] = next.records.count
                next.records.append(value)
            }
        }
        for i in next.records.indices {
            guard let origin = next.records[i].pdfOrigin,!seen.contains(origin.annotationID+":"+String(next.records[i].citations.first?.source.page ?? -1)),next.records[i].citations.contains(where:{ReadingBookIdentity.key($0.source.path)==key && (pages == nil || pages!.contains($0.source.page))}),origin.missingSince == nil else { continue }
            next.records[i].pdfOrigin?.missingSince = now;next.records[i].modified = now
        }
        if next != state { change { $0 = next } }
        pdfCaptureMessage = nil
    }
}
