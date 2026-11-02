import Foundation
import PDFKit

struct ReadingOutputIssue:Identifiable {
    var id:String
    var item:ReadingLibraryID
    var title:String
    var message:String
}
actor ReadingOutputReview {
    static let shared = ReadingOutputReview()
    func inspect(_ snapshot:ReadingExportSnapshot,assets:URL) throws -> [ReadingOutputIssue] {
        var result:[ReadingOutputIssue] = [],pages:[String:Int] = [:],digests:[String:String] = [:]
        for item in snapshot.orderedItems {
            try Task.checkCancellation()
            let target:ReadingLibraryID
            switch item { case .record(let r):target = .record(r.id);case .essay(let e):target = .essay(e.id) }
            func append(_ message:String) { result.append(ReadingOutputIssue(id:item.id+":"+String(result.count),item:target,title:item.title,message:message)) }
            for record in item.records {
                if snapshot.options?.includeQuote != false,let name = record.imageAsset {
                    let file = assets.appendingPathComponent(name)
                    if name != file.lastPathComponent || name.contains("..") { append("摘录图片路径无效") }
                    else if let data = try? Data(contentsOf:file), (try? SignatureImage.loadData(data)) != nil {} else { append("摘录图片缺失或无法读取") }
                }
                if record.citations.isEmpty { append("未填写出处") }
                for citation in record.citations {
                    if citation.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { append("出处缺少书名") }
                    if (citation.edition ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { append("《"+citation.title+"》尚未填写版本") }
                    if citation.source.pageLabel?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false { append("《"+citation.title+"》尚未核对印刷页码") }
                    let path = citation.source.path
                    guard !path.isEmpty,FileManager.default.fileExists(atPath:path) else { append("《"+citation.title+"》原文链接失效");continue }
                    // Never cause an iCloud download in an advisory check.
                    let file = URL(fileURLWithPath:path),resource = try? file.resourceValues(forKeys:[.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey])
                    if resource?.isUbiquitousItem == true,resource?.ubiquitousItemDownloadingStatus == .notDownloaded { append("《"+citation.title+"》尚未下载，页码暂未检查");continue }
                    if let expected = citation.source.fingerprint {
                        if digests[path] == nil { digests[path] = try FileBaseline.capture(file).digest }
                        if digests[path] != expected { append("《"+citation.title+"》原文内容已变化，请核对版本与定位") }
                    }
                    if pages[path] == nil { pages[path] = autoreleasepool { PDFDocument(url:file)?.pageCount ?? 0 } }
                    if pages[path] == 0 { append("《"+citation.title+"》原文暂不可读取") }
                    else if citation.source.page >= pages[path]! { append("《"+citation.title+"》来源页码超出文献范围") }
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
