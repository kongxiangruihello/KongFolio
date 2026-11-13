import Foundation
import AppKit
import PDFKit

extension WorkspaceStore {
    var openBatchDocuments:[Workspace] { tabs.compactMap(\.workspace).filter{openBatchIDs.contains($0.id) && ($0.sourceURL != nil || $0.projectURL != nil)} }
    var canStopOpenBatch:Bool { openBatchDocuments.contains{$0.isImporting || ($0.needsLoad && $0.count == 0)} }
    var openBatchSummary:String {
        let values = openBatchDocuments, loaded = values.filter{$0.count>0}.count
        return values.isEmpty ? "尚无本批读取任务" : "本批 \(values.count) 份 · 已载入 \(loaded) · 等待 \(values.filter{$0.needsLoad && $0.count == 0}.count) · 读取中 \(values.filter(\.isImporting).count)"
    }
    func stopRemainingBatch() {
        for w in openBatchDocuments where w.count == 0 {
            if w.isImporting { w.cancelImport() }
            w.needsLoad = false;w.status = "本批读取已停止；可单独重试"
        }
    }
}
struct ReadingLibrarySession:Codable,Equatable {
    static let key = "KongFolio.readingLibrarySession049"
    var query = "",kind = "全部",tag = "",topic = ""
    var recent = false,untagged = false,removed = false
    var page = 0,size = 10
    static func load(_ defaults:UserDefaults)->Self { guard let data = defaults.data(forKey:key),let value = try? JSONDecoder().decode(Self.self,from:data),[10,20,50].contains(value.size),value.page>=0 else { return Self() };return value }
    func save(_ defaults:UserDefaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data,forKey:Self.key) } }
}
extension ReadingLibraryItem {
    var sourceSummary:String {
        citations053.first?.display ?? ""
    }
    func matchingContext(_ query:String)->String? {
        guard !query.isEmpty,query.utf16.count<=500 else { return nil }
        func context(_ text:String)->String? {
            let ns=text as NSString,r=ns.range(of:query,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive])
            guard r.location != NSNotFound else { return nil }
            let start=max(0,r.location-18),end=min(ns.length,NSMaxRange(r)+35)
            return ns.substring(with:NSRange(location:start,length:end-start)).replacingOccurrences(of:"\n",with:" ↵ ")
        }
        switch self {
        case .record(let r):return context(r.quote) ?? context(r.excerptRemark ?? "") ?? context(r.note)
        case .essay(let e):for block in e.blocks { if let hit=context(block.text) ?? context(block.record?.quote ?? "") ?? context(block.record?.note ?? "") { return hit } };return nil
        }
    }
}
enum ReadingQuoteTools {
    enum Script:String,CaseIterable { case unchanged = "保持原字形",traditional = "转为繁体",simplified = "转为简体" }
    private static func join(_ text:String)->String {
        var result = ""
        for line in text.components(separatedBy:"\n").map({$0.trimmingCharacters(in:.whitespaces)}) where !line.isEmpty { if let a = result.last,let b = line.first,!(ExcerptText.isCJK(a) && ExcerptText.isCJK(b)) { result += " " };result += line };return result
    }
    static func preview(_ text:String,script:Script,joinLines:Bool)->String {
        var value = text
        if joinLines { value = text.components(separatedBy:"\n\n").map{join($0)}.joined(separator:"\n\n") }
        switch script { case .unchanged:break;case .traditional:value = value.applyingTransform(StringTransform("Simplified-Traditional"),reverse:false) ?? value;case .simplified:value = value.applyingTransform(StringTransform("Traditional-Simplified"),reverse:false) ?? value }
        return value
    }
}
extension ReadingJournal {
    func applyQuoteCorrection(_ expected:ReadingRecord,text:String,segmentID:UUID? = nil) throws {
        let message = "摘录正文已变化，请重新打开对照，避免覆盖新内容"
        guard !unreadable,let current = record(expected.id),current.removed == nil else { throw FolioError(message:message) }
        if let segmentID {
            guard let baseline = expected.excerptSegments?.first(where:{$0.id == segmentID}),
                  let live = current.excerptSegments?.first(where:{$0.id == segmentID}),
                  live.text == baseline.text,live.originalText == baseline.originalText else {
                throw FolioError(message:message)
            }
            guard live.text != text else { return }
            try Self.validateCorrection(text,was:live.text)
            editRecord(expected.id) { $0.reviseExcerptSegment(segmentID,text:text) }
            return
        }
        guard current.excerptSegments == nil, current.quote == expected.quote,
              current.originalQuote == expected.originalQuote,current.originalOCR == expected.originalOCR else {
            throw FolioError(message:message)
        }
        guard current.quote != text else { return }
        try Self.validateCorrection(text,was:current.quote)
        editRecord(expected.id) {
            if $0.originalQuote == nil, !$0.quote.isEmpty { $0.originalQuote = $0.quote }
            $0.quote = text
        }
    }

    private static func validateCorrection(_ text:String,was:String) throws {
        if !was.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
           text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            throw FolioError(message:"校订文字为空，请保留至少一段文字")
        }
    }

}

/// Read back the generated file before atomic replacement of the destination.
enum ReadingExportAudit {
    static func validate(_ url:URL,format:ReadingRecordExport.Format,snapshot:ReadingExportSnapshot) throws {
        try Task.checkCancellation()
        let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
        guard !bytes.isEmpty else { throw FolioError(message:"导出文件为空，原有文件未替换") }
        switch format {
        case .pdf:
            guard let pdf = PDFDocument(data:bytes),!pdf.isLocked,pdf.pageCount>0 else { throw FolioError(message:"导出 PDF 无法重新读取") }
        case .markdown:
            guard let text = String(data:bytes,encoding:.utf8),text.hasPrefix("# ") else { throw FolioError(message:"导出 Markdown 无法重新读取") }
        case .word:
            let entries = try storedZIP(bytes)
            guard entries["[Content_Types].xml"] != nil,let xml = entries["word/document.xml"],XMLParser(data:xml).parse() else { throw FolioError(message:"导出 Word 结构校验失败") }
        }
    }
    // Our Word writer emits stored entries with sizes in the local header (no compression/data descriptors).
    static func storedZIP(_ data:Data) throws -> [String:Data] {
        var result:[String:Data] = [:],offset = 0
        func number(_ at:Int,_ length:Int)->Int { (0..<length).reduce(0){$0 | Int(data[at+$1]) << ($1*8)} }
        while offset+4<=data.count,number(offset,4)==0x04034b50 {
            guard offset+30<=data.count else { throw FolioError(message:"Word 压缩包头部损坏") }
            let size = number(offset+18,4),name = number(offset+26,2),extra = number(offset+28,2),start = offset+30+name+extra
            guard number(offset+8,2)==0,start<=data.count,size<=data.count-start,let key = String(data:data[offset+30..<offset+30+name],encoding:.utf8),result[key]==nil else { throw FolioError(message:"Word 内容目录损坏") }
            let content = Data(data[start..<start+size]);guard Int(ZipWriter.crc32(content)) == number(offset+14,4) else { throw FolioError(message:"Word 内容校验失败") };result[key] = content;offset = start+size
        }
        guard offset+4<=data.count,number(offset,4)==0x02014b50 else { throw FolioError(message:"Word 内容目录不完整") }
        return result
    }
}

/// Portable personal data; only these files/keys are accepted, and restore never replaces an existing setting.
enum PersonalReadingBackup {
    static let files = ["Signatures.json","SignaturePositions.json","DocumentIdentity053.json"]
    static let keys = ["Reading.options053",ReadingColorSemantics053.key,EditorDisplayOptions.key,ReaderToolbarProfile.key,ReadingExportPreferences.key,"KongFolio.readingExportProfiles",ReadingLibrarySession.key,"KongFolio.focusedReadingMode","KongFolio.maximumLoadedTabs","KongFolio.memoryBudgetMB","KongFolio.idleTabSeconds",ReadingLaunchPolicy.key,"readingRecordsPageSize"]
    static func settings(_ defaults:UserDefaults) throws -> Data { try PropertyListSerialization.data(fromPropertyList:Dictionary(uniqueKeysWithValues:keys.compactMap{key in defaults.object(forKey:key).map{(key,$0)}}),format:.binary,options:0) }
    static func validate(_ assets:[ResearchBackup.Asset]) throws {
        for asset in assets {
            switch asset.path {
            case "Personal/Signatures.json":
                let values = try JSONDecoder().decode([SignatureTemplate].self,from:asset.bytes)
                guard values.count<=1000,Set(values.map(\.id)).count == values.count else { throw FolioError(message:"备份签名库无效") }
            case "Personal/SignaturePositions.json":
                let values = try JSONDecoder().decode([SignaturePosition].self,from:asset.bytes)
                guard values.count<=1000,values.allSatisfy({$0.centerX.isFinite && $0.centerY.isFinite && $0.width.isFinite && (0...1).contains($0.centerX) && (0...1).contains($0.centerY) && $0.width>0 && $0.width<=1}) else { throw FolioError(message:"备份签名位置无效") }
            case "Personal/Settings.plist":
                guard let values = try PropertyListSerialization.propertyList(from:asset.bytes,options:[],format:nil) as? [String:Any],Set(values.keys).isSubset(of:Set(keys)) else { throw FolioError(message:"备份设置包含不支持的内容") }
            case "Personal/DocumentIdentity053.json":
                let values=try JSONDecoder().decode([ReadingDocumentIdentity053].self,from:asset.bytes)
                guard values.count<=100000,Set(values.map(\.id)).count==values.count,values.allSatisfy({$0.paths.count<=10000 && $0.paths.allSatisfy{$0.hasPrefix("/") && !$0.contains("\0")}}) else { throw FolioError(message:"备份的文献标识无效") }
            default:throw FolioError(message:"备份个人资料路径无效")
            }
        }
    }
    @MainActor static func merge(from folder:URL,storage:URL,defaults:UserDefaults) throws {
        guard FileManager.default.fileExists(atPath:folder.path) else { return }
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        let identitySource=folder.appendingPathComponent("DocumentIdentity053.json"),identityFile=storage.appendingPathComponent("DocumentIdentity053.json")
        if FileManager.default.fileExists(atPath:identitySource.path) {
            let incoming=try JSONDecoder().decode([ReadingDocumentIdentity053].self,from:Data(contentsOf:identitySource))
            var values=FileManager.default.fileExists(atPath:identityFile.path) ? try JSONDecoder().decode([ReadingDocumentIdentity053].self,from:Data(contentsOf:identityFile)):[]
            for item in incoming where !values.contains(where:{$0.id==item.id || !Set($0.paths).isDisjoint(with:Set(item.paths))}) { values.append(item) }
            try JSONEncoder().encode(values).write(to:identityFile,options:.atomic)
        }
        let incoming = try SignatureLibrary.read(storage:folder),current = try SignatureLibrary.read(storage:storage)
        var signatures = current
        for var value in incoming {
            if signatures.contains(where:{$0.pdf == value.pdf && $0.image == value.image && $0.name == value.name}) { continue }
            if let old = current.first(where:{$0.id == value.id}) { if old.pdf == value.pdf && old.image == value.image { continue };value.id = UUID() }
            signatures.append(value)
        }
        if !incoming.isEmpty { try SignatureLibrary.write(signatures,storage:storage) }
        let positionFile = storage.appendingPathComponent("SignaturePositions.json"),source = folder.appendingPathComponent("SignaturePositions.json")
        if FileManager.default.fileExists(atPath:source.path) {
            let incoming = try JSONDecoder().decode([SignaturePosition].self,from:Data(contentsOf:source))
            var values = FileManager.default.fileExists(atPath:positionFile.path) ? try JSONDecoder().decode([SignaturePosition].self,from:Data(contentsOf:positionFile)) : []
            for var value in incoming { if let old = values.first(where:{$0.id == value.id}) { if old == value { continue };value.id = UUID() };values.append(value) }
            try JSONEncoder().encode(values).write(to:positionFile,options:.atomic)
        }
        let file = folder.appendingPathComponent("Settings.plist")
        if FileManager.default.fileExists(atPath:file.path) {
            let bytes = try Data(contentsOf:file);try validate([ResearchBackup.Asset(path:"Personal/Settings.plist",bytes:bytes,digest:OCRPageCache.digest(bytes))])
            let values = try PropertyListSerialization.propertyList(from:bytes,options:[],format:nil) as! [String:Any]
            for key in keys where defaults.object(forKey:key)==nil { if let value = values[key] { defaults.set(value,forKey:key) } }
        }
    }
}
