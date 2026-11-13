import Foundation
import PDFKit

struct ReadingOutputIssue:Identifiable {
    var id:String
    var item:ReadingLibraryID
    var title:String
    var message:String
    var source: ReadingExportSourceTarget? = nil
}
actor ReadingOutputReview {
    static let shared = ReadingOutputReview()
    func inspect(_ snapshot:ReadingExportSnapshot,assets:URL) throws -> [ReadingOutputIssue] {
        var result:[ReadingOutputIssue] = [],pages:[String:Int] = [:],digests:[String:String] = [:]
        for item in snapshot.orderedItems {
            try Task.checkCancellation()
            let target = item.libraryID
            func append(_ message: String, source: ReadingExportSourceTarget? = nil) {
                result.append(ReadingOutputIssue(id:item.id+":"+String(result.count),item:target,title:item.title,message:message,source:source))
            }
            var inspectedAssets = Set<String>()
            func inspectAsset(_ name: String) {
                guard inspectedAssets.insert(name).inserted else { return }
                let file = assets.appendingPathComponent(name)
                if name != file.lastPathComponent || name.contains("..") { append("摘录图片路径无效") }
                else if let data = try? Data(contentsOf:file), SignatureImage.loadData(data) != nil {} else { append("摘录图片缺失或无法读取") }
            }
            func inspectSources(_ citations: [ReadingCitation], block: UUID?, location: ReadingExportSourceTarget.Location,
                                wholeBook: Bool = false, required: Bool = false) throws {
                guard snapshot.options?.includeSources != false else { return }
                if citations.isEmpty, required {
                    append("未填写出处",source:ReadingExportSourceTarget(item:target,block:block,index:0,location:location))
                }
                for (index,citation) in citations.enumerated() {
                    try Task.checkCancellation()
                    func issue(_ message: String) {
                        append(message,source:ReadingExportSourceTarget(item:target,block:block,index:index,location:location))
                    }
                    if citation.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { issue("出处缺少书名") }
                    if (citation.edition ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { issue("《"+citation.title+"》尚未填写版本") }
                    if citation.source.page < 0 || citation.source.invalidPage053 == true || citation.tracking?.needsReview == true {
                        issue("缺少可用的 PDF 页码，请重新核对原页")
                    }
                    if !wholeBook, citation.source.pageLabel?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false { issue("《"+citation.title+"》尚未核对印刷页码") }
                    let path = citation.source.path
                    guard !path.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { issue("缺少原文链接");continue }
                    let file = URL(fileURLWithPath:path)
                    switch ShelfFileStatus.read(file) {
                    case .missing: issue("《"+citation.title+"》原文链接失效");continue
                    case .cloud: issue("《"+citation.title+"》尚未下载，页码暂未检查");continue
                    case .available: break
                    }
                    if let expected = citation.source.fingerprint {
                        if digests[path] == nil { digests[path] = try? FileBaseline.capture(file).digest }
                        if digests[path] == nil { issue("《"+citation.title+"》原文暂不可读取");continue }
                        if digests[path] != expected { issue("《"+citation.title+"》原文内容已变化，请核对版本与定位") }
                    }
                    if TextImport.handles(file) { continue }
                    if pages[path] == nil { pages[path] = autoreleasepool { ReadingSourceInput(url:file).document()?.pageCount ?? 0 } }
                    if pages[path] == 0 { issue("《"+citation.title+"》原文暂不可读取") }
                    else if citation.source.page >= pages[path]! { issue("《"+citation.title+"》来源页码超出文献范围") }
                }
            }
            func inspectExtras(_ extras: ReadingRecordExtras053?, block: UUID?) throws {
                guard let extras else { return }
                for region in extras.regions ?? [] {
                    if snapshot.options?.includeQuote != false { inspectAsset(region.asset) }
                    try inspectSources([region.citation],block:block,location:.region(region.id))
                }
                for quote in extras.quotations ?? [] {
                    if snapshot.options?.includeQuote != false { (quote.assets ?? []).forEach(inspectAsset) }
                    try inspectSources(quote.citations,block:block,location:.quotation(quote.id),required:true)
                }
                if snapshot.options?.includeQuote != false, snapshot.options?.includeRegionImages == true, let asset = extras.visualAsset {
                    inspectAsset(asset)
                }
            }
            func inspectRecord(_ record: ReadingRecord, block: UUID?) throws {
                if snapshot.options?.includeQuote != false, let asset = record.imageAsset { inspectAsset(asset) }
                let requiresSource = (record.kind != .note || !record.linkedRecords.isEmpty) && record.citations053.isEmpty
                try inspectSources(record.citations,block:block,location:.direct,wholeBook:record.wholeBook,required:requiresSource)
                try inspectExtras(record.extras,block:block)
            }
            switch item {
            case .record(let record): try inspectRecord(record,block:nil)
            case .essay(let essay):
                try inspectExtras(essay.extras,block:nil)
                for block in essay.blocks {
                    if let record = block.record { try inspectRecord(record,block:block.id) }
                }
            }
        }
        return result
    }
}

struct ReadingExportLedger:Codable,Equatable {
    struct Entry:Codable,Equatable { var title:String;var digest:String }
    var version = 1
    var date = Date()
    var entries:[String:Entry]
    static func capture(_ state:ReadingJournalState) throws -> Self {
        var entries:[String:Entry] = [:]
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        for record in state.records where record.removed == nil && record.hasContent {
            entries["r:"+record.id.uuidString] = Entry(title:record.displayTitle,digest:OCRPageCache.digest(try encoder.encode(record)))
        }
        for essay in state.essays where essay.removed == nil && essay.hasContent {
            entries["e:"+essay.id.uuidString] = Entry(title:essay.title,digest:OCRPageCache.digest(try encoder.encode(essay)))
        }
        return Self(entries:entries)
    }
    static func load(_ folder:URL) throws -> Self? {
        let file = folder.appendingPathComponent("ExportLedger.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:file))
        guard value.version == 1,value.entries.values.allSatisfy({$0.digest.count == 64}) else { throw FolioError(message:"上次导出记录无法校验，请保留原文件并处理后重试") }
        return value
    }
}
struct ReadingExportDelta {
    var current:ReadingExportLedger
    var added:[String]
    var modified:[String]
    var removed:[String]
    var old:ReadingExportLedger?
    var hasChanges:Bool { !added.isEmpty || !modified.isEmpty || !removed.isEmpty }
    init(_ state:ReadingJournalState,old:ReadingExportLedger?) throws {
        self.old = old;let captured = try ReadingExportLedger.capture(state);current = captured
        let previous = old?.entries ?? [:]
        added = captured.entries.keys.filter{previous[$0] == nil}.sorted()
        modified = captured.entries.keys.filter{previous[$0] != nil && previous[$0]?.digest != captured.entries[$0]?.digest}.sorted()
        removed = previous.keys.filter{captured.entries[$0] == nil}.sorted()
    }
    func snapshot(_ state:ReadingJournalState,options:ReadingExportOptions) -> ReadingExportSnapshot {
        let ids = Set(added+modified)
        return ReadingExportSnapshot(title:"新增与修改的阅读资料",records:state.records.filter{ids.contains("r:"+$0.id.uuidString)},essays:state.essays.filter{ids.contains("e:"+$0.id.uuidString)},options:options)
    }
    var report:String {
        var text = "# 阅读资料变更清单\n\n"+(old.map{"比较基准："+$0.date.formatted(date:.numeric,time:.standard)} ?? "首次增量导出，包含全部现有记录")+"\n\n"
        for (name,ids) in [("新增",added),("修改",modified),("删除",removed)] { text += "## "+name+"（\(ids.count)）\n\n";for id in ids { let title = name == "删除" ? old?.entries[id]?.title : current.entries[id]?.title;text += "- "+(title ?? id).replacingOccurrences(of:"\n",with:" ")+"\n" };text += "\n" }
        return text+"删除项仅记录名称，不会删除以前导出的文件。普通导出不改变增量导出基准。\n"
    }
}
actor ReadingIncrementalWorker {
    static let shared = ReadingIncrementalWorker()
    func export(_ state:ReadingJournalState,old:ReadingExportLedger?,options:ReadingExportOptions,formats:[ReadingRecordExport.Format],assets:URL,journalFolder:URL,parent:URL) throws -> URL {
        guard !formats.isEmpty,try ReadingExportLedger.load(journalFolder) == old else { throw FolioError(message:"导出基准已变化，请刷新清单") }
        let delta = try ReadingExportDelta(state,old:old)
        guard delta.hasChanges else { throw FolioError(message:"自上次增量导出后没有变化") }
        let folder = parent.appendingPathComponent("KongFolio-增量-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        var success = false;defer { if !success { try? FileManager.default.removeItem(at:folder) } }
        let snapshot = delta.snapshot(state,options:options)
        if !snapshot.orderedItems.isEmpty { for format in formats {
            try Task.checkCancellation();let file = folder.appendingPathComponent("新增与修改."+format.ext)
            try ReadingRecordExport.write(snapshot,format:format,assets:assets,to:file,expected:FileBaseline(path:file.path,digest:nil))
        } }
        try delta.report.write(to:folder.appendingPathComponent("变更清单.md"),atomically:true,encoding:.utf8)
        try Task.checkCancellation()
        guard try ReadingExportLedger.load(journalFolder) == old else { throw FolioError(message:"导出期间基准已变化，未提交本次导出") }
        try JSONEncoder().encode(delta.current).write(to:journalFolder.appendingPathComponent("ExportLedger.json"),options:.atomic)
        success = true;return folder
    }
}
