import Foundation

struct SavedReadingFilter: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query = ""
    var kind = "全部"
    var tag = ""
    var topic = ""
    var recent = false
    var untagged = false
    var removed = false
    var page = 0
    var size = 10
    static func load(_ folder: URL) throws -> [Self] {
        let file = folder.appendingPathComponent("Filters.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        let values = try JSONDecoder().decode([Self].self,from:Data(contentsOf:file))
        guard values.count <= 100, Set(values.map(\.id)).count == values.count else { throw FolioError(message:"常用筛选格式无效，原文件已保留") }
        return values
    }
    static func save(_ values:[Self],folder:URL) throws {
        guard values.count <= 100,Set(values.map(\.id)).count == values.count,values.allSatisfy({!$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.page >= 0 && [10,20,50].contains($0.size)}) else { throw FolioError(message:"筛选名称或分页设置无效，最多保存 100 项") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try JSONEncoder().encode(values).write(to:folder.appendingPathComponent("Filters.json"),options:.atomic)
    }
}
extension ReadingJournal {
    var allTags:[String] { Array(Set(state.records.filter{$0.removed == nil}.flatMap(\.tags)+state.essays.filter{$0.removed == nil}.flatMap(\.tags))).filter{!$0.isEmpty}.sorted() }
    func tagSuggestions(_ input:String) -> [String] {
        let last = input.replacingOccurrences(of:"，",with:",").components(separatedBy:",").last?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let used = Self.normalizedTags(input)
        return Array(allTags.filter{!used.contains($0) && (last.isEmpty || AnnotationFilter.folded($0).contains(AnnotationFilter.folded(last)))}.prefix(8))
    }
    func renameTag(_ old:String,to raw:String) throws {
        let new = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !unreadable,!old.isEmpty,!new.isEmpty,!new.contains(","),!new.contains("，") else { throw FolioError(message:"请输入一个有效标签名称") }
        guard old != new else { return }
        func renamed(_ tags:[String]) -> [String] { var seen = Set<String>(); return tags.map{$0 == old ? new : $0}.filter{seen.insert($0).inserted} }
        change { value in
            for i in value.records.indices where value.records[i].tags.contains(old) { value.records[i].tags = renamed(value.records[i].tags);value.records[i].modified = Date() }
            for i in value.essays.indices where value.essays[i].tags.contains(old) { value.essays[i].tags = renamed(value.essays[i].tags);value.essays[i].modified = Date() }
        }
    }
}

struct ReadingRelinkProposal: Identifiable {
    var id:String { old }
    var old:String
    var candidates:[URL]
    var requiredPage:Int
    var title:String { URL(fileURLWithPath:old).lastPathComponent }
}
actor ReadingRelinkWorker {
    static let shared = ReadingRelinkWorker()
    func scan(_ state:ReadingJournalState,folder:URL) throws -> [ReadingRelinkProposal] {
        let citations = (state.records+state.essays.flatMap{$0.blocks.compactMap(\.record)}).flatMap(\.citations)
        let groups = Dictionary(grouping:citations.filter{!$0.source.path.isEmpty && !FileManager.default.fileExists(atPath:$0.source.path)},by:{$0.source.path})
        guard !groups.isEmpty else { return [] }
        guard let enumerator = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { throw FolioError(message:"无法读取所选目录") }
        var files:[String:[URL]] = [:],count = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation();count += 1
            guard count <= 20000 else { throw FolioError(message:"目录内容超过 20,000 项，请选择更小的文献文件夹") }
            let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true,values.isRegularFile == true,file.pathExtension.lowercased() == "pdf" else { continue }
            files[file.lastPathComponent,default:[]].append(file)
        }
        return groups.keys.sorted().map { old in ReadingRelinkProposal(old:old,candidates:(files[URL(fileURLWithPath:old).lastPathComponent] ?? []).sorted{$0.path<$1.path},requiredPage:groups[old]!.map{$0.source.page}.max() ?? 0) }
    }
    func validate(_ selections:[String:URL],proposals:[ReadingRelinkProposal]) throws {
        for (old,file) in selections {
            try Task.checkCancellation()
            guard let proposal = proposals.first(where:{$0.old == old}),let pdf = PDFDocument(url:file),!pdf.isLocked,pdf.pageCount>proposal.requiredPage else { throw FolioError(message:"文献无法读取或页数不足："+file.lastPathComponent) }
        }
    }
}
import PDFKit

extension ReadingJournal {
    func relinkBatch(_ mapping:[String:URL]) {
        let normalized = mapping.mapValues{ReadingProgress.canonicalPath($0.path)}
        func update(_ record:inout ReadingRecord) -> Bool {
            var changed = false
            for i in record.citations.indices { if let path = normalized[record.citations[i].source.path] { record.citations[i].source.path = path;record.citations[i].source.relativePath = nil;record.citations[i].source.fingerprint = nil;changed = true } }
            if changed { record.modified = Date() };return changed
        }
        change { value in
            for i in value.records.indices { _ = update(&value.records[i]) }
            for i in value.essays.indices { var changed = false;for j in value.essays[i].blocks.indices { if var record = value.essays[i].blocks[j].record { changed = update(&record) || changed;value.essays[i].blocks[j].record = record } };if changed { value.essays[i].modified = Date() } }
            for (old,path) in normalized { if let id = value.lastNotes.removeValue(forKey:old) { value.lastNotes[path] = id } }
        }
    }
}
