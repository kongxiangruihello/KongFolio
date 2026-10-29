import Foundation

struct ReadingCitation: Codable, Equatable {
    var source: SourceRef
    var title: String
    var author = ""
    var display: String { (author.isEmpty ? "" : author + "：") + "《" + title + "》，" + source.pageDescription }
}
struct ReadingRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case excerpt = "摘录", image = "图片摘录", note = "笔记" }
    var id = UUID()
    var kind: Kind
    var title = ""
    var quote = ""
    var note = ""
    var citations: [ReadingCitation] = []
    var linkedRecords: [UUID] = []
    var imageAsset: String?
    var tags: [String] = []
    var created = Date()
    var modified = Date()
    var removed: Date?
    var wholeBook = false
    var displayTitle: String {
        if !title.isEmpty { return title }
        let text = kind == .note ? note : quote
        return String(text.split(separator:"\n").first?.prefix(48) ?? Substring(kind.rawValue))
    }
    func matches(_ query:String, book:String? = nil, tag:String = "", after:Date? = nil) -> Bool {
        if let book, !citations.contains(where: { $0.source.path == book }) { return false }
        if !tag.isEmpty && !tags.contains(tag) { return false }
        if let after, modified < after { return false }
        let haystack = title + "\n" + quote + "\n" + note + "\n" + tags.joined(separator:" ") + "\n" + citations.map { $0.title + $0.author + $0.source.pageDescription }.joined(separator:"\n")
        return query.isEmpty || AnnotationFilter.folded(haystack).contains(AnnotationFilter.folded(query))
    }
}
struct ReadingEssay: Codable, Identifiable, Equatable {
    struct Block: Codable, Identifiable, Equatable {
        var id = UUID()
        var text = ""
        /// A citation is frozen when inserted: subsequent card edits cannot silently rewrite an essay.
        var record: ReadingRecord?
    }
    var id = UUID()
    var title = "未命名札记"
    var blocks: [Block] = [Block()]
    var tags: [String] = []
    var created = Date()
    var modified = Date()
    var removed: Date?
    func matches(_ query:String) -> Bool {
        if query.isEmpty { return true }
        let paragraphs = blocks.map { block -> String in
            let sources = block.record?.citations.map(\.display).joined(separator:" ") ?? ""
            return [block.text,block.record?.quote ?? "",block.record?.note ?? "",sources].joined(separator:"\n")
        }
        let text = ([title,tags.joined(separator:" ")]+paragraphs).joined(separator:"\n")
        return AnnotationFilter.folded(text).contains(AnnotationFilter.folded(query))
    }
    mutating func move(_ id:UUID,delta:Int) {
        guard let i = blocks.firstIndex(where:{$0.id == id}), blocks.indices.contains(i+delta) else { return }
        blocks.swapAt(i,i+delta); modified = Date()
    }
}
struct ReadingJournalState: Codable, Equatable {
    var version = 1
    var records: [ReadingRecord] = []
    var essays: [ReadingEssay] = []
    var currentEssay: UUID?
    var lastNotes: [String:UUID] = [:]
    func validate() throws {
        guard version == 1, Set(records.map(\.id)).count == records.count, Set(essays.map(\.id)).count == essays.count else { throw FolioError(message:"阅读记录格式或编号无效，原文件已保留") }
        for record in records + essays.flatMap({$0.blocks.compactMap(\.record)}) {
            if let image = record.imageAsset {
                guard image == URL(fileURLWithPath:image).lastPathComponent, !image.contains(".."), !image.contains("/"), !image.contains("\\") else { throw FolioError(message:"摘录图片路径无效") }
            }
            guard record.citations.allSatisfy({ $0.source.page >= 0 && $0.source.rects.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite } }) else { throw FolioError(message:"摘录来源无效") }
        }
    }
}
actor ReadingJournalWriter {
    private var latest = -1
    func write(_ state:ReadingJournalState, revision:Int, assets:[String:Data], folder:URL) throws {
        guard revision >= latest else { return }
        try state.validate()
        let fm = FileManager.default, assetFolder = folder.appendingPathComponent("Assets")
        try fm.createDirectory(at:assetFolder,withIntermediateDirectories:true)
        for (name,data) in assets {
            guard name == URL(fileURLWithPath:name).lastPathComponent else { throw FolioError(message:"图片名称无效") }
            let file = assetFolder.appendingPathComponent(name)
            if !fm.fileExists(atPath:file.path) { try data.write(to:file,options:.atomic) }
        }
        let file = folder.appendingPathComponent("catalog.json")
        let bytes = try JSONEncoder().encode(state)
        if let old = try? Data(contentsOf:file), (try? JSONDecoder().decode(ReadingJournalState.self,from:old)) != nil {
            try old.write(to:folder.appendingPathComponent("catalog.previous.json"),options:.atomic)
        }
        try bytes.write(to:file,options:.atomic); latest = revision
    }
}
@MainActor final class ReadingJournal: ObservableObject {
    @Published private(set) var state = ReadingJournalState()
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    @Published private(set) var dirty = false
    private(set) var unreadable = false
    let folder: URL
    private let writer = ReadingJournalWriter()
    private var revision = 0
    private var savedRevision = 0
    private var pendingAssets: [String:Data] = [:]
    private var timer: Task<Void,Never>?
    private var worker: Task<Void,Error>?
    init(storage:URL) {
        folder = storage.appendingPathComponent("ReadingJournal",isDirectory:true)
        let file = folder.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return }
        do { let value = try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:file)); try value.validate(); state = value }
        catch { unreadable = true; self.error = "阅读记录未能读取，原记录保留：" + error.localizedDescription }
    }
    func record(_ id:UUID?) -> ReadingRecord? { state.records.first { $0.id == id } }
    func essay(_ id:UUID?) -> ReadingEssay? { state.essays.first { $0.id == id } }
    func assetURL(_ name:String) -> URL { folder.appendingPathComponent("Assets").appendingPathComponent(name) }
    var saveStatus:String { error ?? (saving ? "正在保存记录…" : (dirty ? "等待保存…" : "记录已自动保存")) }
    func change(_ operation:(inout ReadingJournalState)->Void) {
        guard !unreadable else { return }
        operation(&state); revision += 1; dirty = true
        timer?.cancel(); timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:250_000_000) } catch { return }
            guard let self else { return }; do { try await self.flush() } catch { self.error = "阅读记录尚未保存：" + error.localizedDescription }
        }
    }
    @discardableResult func add(_ record:ReadingRecord,image:Data? = nil) -> UUID {
        guard !unreadable else { return record.id }
        var record = record
        if let image { let name = OCRPageCache.digest(image)+".png"; pendingAssets[name] = image; record.imageAsset = name }
        change { value in
            if let index = value.records.firstIndex(where:{$0.id == record.id}) { value.records[index] = record } else { value.records.append(record) }
            for citation in record.citations { value.lastNotes[citation.source.path] = record.id }
        }
        return record.id
    }
    func editRecord(_ id:UUID,_ edit:(inout ReadingRecord)->Void) {
        guard let i = state.records.firstIndex(where:{$0.id == id}) else { return }
        change { value in edit(&value.records[i]); value.records[i].modified = Date(); for citation in value.records[i].citations { value.lastNotes[citation.source.path] = id } }
    }
    @discardableResult func newEssay(title:String = "未命名札记") -> UUID {
        let essay = ReadingEssay(title:title)
        change { $0.essays.append(essay); $0.currentEssay = essay.id }; return essay.id
    }
    func editEssay(_ id:UUID,_ edit:(inout ReadingEssay)->Void) {
        guard let i = state.essays.firstIndex(where:{$0.id == id}) else { return }
        change { value in edit(&value.essays[i]); value.essays[i].modified = Date() }
    }
    func insert(_ record:ReadingRecord,in essay:UUID) { editEssay(essay) { $0.blocks.append(ReadingEssay.Block(record:record)) } }
    func selectEssay(_ id:UUID) { guard state.currentEssay != id else { return }; change { $0.currentEssay = id } }
    func relink(old:String,to url:URL,recordID:UUID? = nil) {
        let newPath = ReadingProgress.canonicalPath(url.path)
        func update(_ record:inout ReadingRecord) {
            guard recordID == nil || record.id == recordID else { return }
            for i in record.citations.indices where record.citations[i].source.path == old { record.citations[i].source.path = newPath; record.citations[i].source.relativePath = nil; record.citations[i].source.fingerprint = nil }
        }
        change { value in
            for i in value.records.indices { update(&value.records[i]) }
            for i in value.essays.indices { for j in value.essays[i].blocks.indices { if var record = value.essays[i].blocks[j].record { update(&record); value.essays[i].blocks[j].record = record } } }
            if let last = value.lastNotes.removeValue(forKey:old) { value.lastNotes[newPath] = last }
        }
    }
    func flush() async throws {
        timer?.cancel(); timer = nil
        if unreadable { throw FolioError(message:error ?? "阅读记录无法读取") }
        while let worker { try await worker.value; await Task.yield() }
        guard savedRevision != revision || !pendingAssets.isEmpty else { return }
        saving = true
        let value = state, number = revision, assets = pendingAssets, destination = folder, writer = writer
        let task = Task { try await writer.write(value,revision:number,assets:assets,folder:destination) }
        worker = task
        do {
            try await task.value
            worker = nil; savedRevision = number; for name in assets.keys { pendingAssets[name] = nil }
            dirty = revision != number; error = nil; saving = false
        } catch { worker = nil; saving = false; dirty = true; self.error = "阅读记录尚未保存：" + error.localizedDescription; throw error }
        if dirty { try await flush() }
    }
    func recoverPrevious() throws {
        let fm = FileManager.default, old = folder.appendingPathComponent("catalog.previous.json"), file = folder.appendingPathComponent("catalog.json")
        let bytes = try Data(contentsOf:old), recovered = try JSONDecoder().decode(ReadingJournalState.self,from:bytes); try recovered.validate()
        if fm.fileExists(atPath:file.path) { try fm.copyItem(at:file,to:folder.appendingPathComponent("catalog.damaged-"+UUID().uuidString+".json")) }
        try bytes.write(to:file,options:.atomic); state = recovered; unreadable = false; error = nil
    }
    /// Import only the old app's stored records. No PDF is opened or implicitly added to the manual bookshelf.
    func importLegacy(cards:[BoardCard],books:[LibraryBook],topics:[ResearchTopic],annotations:[ResearchAnnotation]) async {
        guard !unreadable else { return }
        let known = Set(state.records.map(\.id)), knownTopics = Set(state.essays.map(\.id))
        let batch = await Task.detached(priority:.utility) { Self.prepareLegacy(cards:cards,books:books,topics:topics,annotations:annotations,knownRecords:known,knownTopics:knownTopics) }.value
        guard !Task.isCancelled else { return }
        merge(batch)
    }
    func merge(_ batch:ReadingJournalTransfer) {
        let existing = Set(state.records.map(\.id)), essayIDs = Set(state.essays.map(\.id))
        let records = batch.state.records.filter { !existing.contains($0.id) }, essays = batch.state.essays.filter { !essayIDs.contains($0.id) }
        guard !records.isEmpty || !essays.isEmpty else { return }
        pendingAssets.merge(batch.assets) { current,_ in current }
        change { $0.records += records; $0.essays += essays }
    }
    func pendingImage(_ name:String) -> Data? { pendingAssets[name] }
    nonisolated private static func prepareLegacy(cards:[BoardCard],books:[LibraryBook],topics:[ResearchTopic],annotations:[ResearchAnnotation],knownRecords:Set<UUID>,knownTopics:Set<UUID>) -> ReadingJournalTransfer {
        var assets:[String:Data] = [:]
        var additions:[ReadingRecord] = [], essays:[ReadingEssay] = [], known = knownRecords, knownEssays = knownTopics
        for card in cards where known.insert(card.id).inserted {
            var record = ReadingRecord(id:card.id,kind:card.kind == .note ? .note : (card.kind == .image ? .image : .excerpt),quote:card.kind == .note ? "" : card.text,note:card.kind == .note ? card.text : card.comment)
            if let source = card.source { record.citations = [ReadingCitation(source:source,title:source.fileName)] }
            if let data = card.imageData { let name = OCRPageCache.digest(data)+".png"; record.imageAsset = name; assets[name] = data }
            additions.append(record)
        }
        for book in books where !book.reflection.isEmpty {
            let id = Self.stableID("reflection:"+book.id.uuidString)
            guard known.insert(id).inserted else { continue }
            additions.append(ReadingRecord(id:id,kind:.note,title:"整本书心得",note:book.reflection,citations:[ReadingCitation(source:SourceRef(path:book.path,fileName:book.title,page:0),title:book.title)],wholeBook:true))
        }
        for annotation in annotations {
            let record = Self.legacyAnnotation(annotation)
            if known.insert(record.id).inserted { additions.append(record) }
        }
        for topic in topics where knownEssays.insert(topic.id).inserted {
            var essay = ReadingEssay(id:topic.id,title:topic.name,blocks:[ReadingEssay.Block(text:topic.introduction)])
            for item in topic.items { essay.blocks.append(ReadingEssay.Block(text:item.reflection,record:Self.legacyAnnotation(item.annotation))) }
            essays.append(essay)
        }
        var paths:[String:String] = [:]
        func normalize(_ record:inout ReadingRecord) {
            for i in record.citations.indices {
                let path = record.citations[i].source.path; guard !path.isEmpty else { continue }
                let canonical = paths[path] ?? ReadingProgress.canonicalPath(path); paths[path] = canonical; record.citations[i].source.path = canonical
            }
        }
        for i in additions.indices { normalize(&additions[i]) }
        for i in essays.indices { for j in essays[i].blocks.indices { if var record = essays[i].blocks[j].record { normalize(&record); essays[i].blocks[j].record = record } } }
        return ReadingJournalTransfer(state:ReadingJournalState(records:additions,essays:essays),assets:assets)
    }
    nonisolated private static func legacyAnnotation(_ note:ResearchAnnotation) -> ReadingRecord {
        ReadingRecord(id:stableID("annotation:"+note.key),kind:note.quote.isEmpty ? .note : .excerpt,quote:note.quote,note:note.comment,citations:[ReadingCitation(source:SourceRef(path:note.path,fileName:URL(fileURLWithPath:note.path).lastPathComponent,page:note.page),title:URL(fileURLWithPath:note.path).deletingPathExtension().lastPathComponent)],tags:note.tags,created:note.modified,modified:note.modified)
    }
    nonisolated static func stableID(_ value:String) -> UUID {
        let hex = String(OCRPageCache.digest(Data(value.utf8)).prefix(32)); let chars = Array(hex)
        return UUID(uuidString:[String(chars[0..<8]),String(chars[8..<12]),String(chars[12..<16]),String(chars[16..<20]),String(chars[20..<32])].joined(separator:"-"))!
    }
}

struct ReadingJournalTransfer {
    var state:ReadingJournalState
    var assets:[String:Data]
    static func read(_ folder:URL) throws -> Self? {
        let file = folder.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let state = try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:file)); try state.validate()
        var assets:[String:Data] = [:]
        for name in Set((state.records+state.essays.flatMap{$0.blocks.compactMap(\.record)}).compactMap(\.imageAsset)) { try Task.checkCancellation(); assets[name] = try Data(contentsOf:folder.appendingPathComponent("Assets").appendingPathComponent(name),options:.mappedIfSafe) }
        return Self(state:state,assets:assets)
    }
}
