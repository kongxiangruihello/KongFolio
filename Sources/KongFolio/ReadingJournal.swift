import Foundation

struct ReadingCitation: Codable, Equatable {
    var source: SourceRef
    var title: String
    var author = ""
    var edition:String? = nil
    var publication:ReadingPublication053? = nil
    var tracking:ReadingSourceIdentity053? = nil
    var display: String { (author.isEmpty ? "" : author + "：") + "《" + title + "》，" + source.pageDescription }
}
struct ReadingRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case excerpt = "摘录", image = "图片摘录", note = "笔记", annotation = "标注", comment = "PDF 评论" }
    var id = UUID()
    var kind: Kind
    var title = ""
    var quote = ""
    var note = ""
    var originalQuote:String? = nil
    var originalOCR:String? = nil
    var ocrSegments:[ReadingOCRSegment]? = nil
    var citations: [ReadingCitation] = []
    var linkedRecords: [UUID] = []
    var imageAsset: String?
    var tags: [String] = []
    var created = Date()
    var modified = Date()
    var removed: Date?
    var wholeBook = false
    var pdfOrigin:ReadingPDFOrigin? = nil
    var extras:ReadingRecordExtras053? = nil
    var excerptRemark: String? = nil
    var excerptSegments: [ReadingExcerptSegment]? = nil
    var hasContent: Bool {
        let heading = wholeBook && title == "整本书心得" ? "" : title
        return pdfOrigin != nil || extras?.hasContent == true || [heading, quote, note, excerptRemark ?? ""].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || imageAsset != nil || !linkedRecords.isEmpty || tags.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var displayTitle: String {
        if !title.isEmpty { return title }
        let text = pdfOrigin.map { quote.isEmpty ? ($0.contents.isEmpty ? "标注 · "+$0.type : $0.contents) : quote } ?? (kind == .note ? note : quote)
        return String(text.split(separator:"\n").first?.prefix(48) ?? Substring(kind.rawValue))
    }
    var canChangeNoteSource: Bool {
        kind == .note && removed == nil && linkedRecords.isEmpty && quote.isEmpty && citations053.count <= 1 &&
            (extras?.hasContent != true) && imageAsset == nil
    }
    var noteSourceSummary: String {
        let sources = citations053
        guard let first = sources.first else { return "独立笔记" }
        let title = first.title.isEmpty ? first.source.fileName : first.title
        let location = wholeBook ? "整本书" : first.source.pageDescription
        return "《" + title + "》 · " + location + (sources.count > 1 ? " · 共 \(sources.count) 处" : "")
    }
    func matches(_ query:String, book:String? = nil, tag:String = "", after:Date? = nil) -> Bool {
        if let book, !citations.contains(where: { ReadingBookIdentity.key($0.source.path) == ReadingBookIdentity.key(book) }) { return false }
        if !tag.isEmpty && !tags.contains(tag) { return false }
        if let after, modified < after { return false }
        let sourceText = citations.map { [$0.title,$0.author,$0.source.pageDescription].joined(separator:" ") }.joined(separator:"\n")
        let haystack = [pdfOrigin?.contents ?? "",title,quote,note,excerptRemark ?? "",tags.joined(separator:" "),sourceText].joined(separator:"\n")
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
    var title = "未命名笔记"
    var blocks: [Block] = [Block()]
    var tags: [String] = []
    var created = Date()
    var modified = Date()
    var removed: Date?
    var extras:ReadingRecordExtras053? = nil
    var hasContent: Bool {
        extras?.hasContent == true || (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !["未命名札记","未命名笔记"].contains(title)) || tags.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || blocks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.record?.hasContent == true }
    }
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
        for name in assetNames053 { guard !name.isEmpty,name==URL(fileURLWithPath:name).lastPathComponent,!name.contains(".."),!name.contains("/"),!name.contains("\\") else { throw FolioError(message:"资料图片路径无效") } }
        for record in records + essays.flatMap({$0.blocks.compactMap(\.record)}) {
            if let segments = record.ocrSegments { guard segments.count <= 10000,Set(segments.map(\.id)).count == segments.count,segments.allSatisfy({$0.box.minX.isFinite && $0.box.minY.isFinite && $0.box.width.isFinite && $0.box.height.isFinite}) else { throw FolioError(message:"摘录校订段落无效") } }
            for image in record.assetNames053 {
                guard image == URL(fileURLWithPath:image).lastPathComponent, !image.contains(".."), !image.contains("/"), !image.contains("\\") else { throw FolioError(message:"摘录图片路径无效") }
            }
            guard (record.citations+(record.extras?.regions ?? []).map(\.citation)+(record.extras?.quotations ?? []).flatMap(\.citations)).allSatisfy({ $0.source.page >= 0 && $0.source.rects.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite } }) else { throw FolioError(message:"摘录来源无效") }
        }
    }
}
actor ReadingJournalWriter {
    private var latest = -1
    private var incrementalCache:ReadingDeltaStorage.Loaded?
    private var dailyChecked:Date?
    private(set) var backupError:String?
    func write(_ state:ReadingJournalState, revision:Int, assets:[String:Data], folder:URL, incremental:Bool = false) async throws {
        guard revision >= latest else { return }
        try state.validate()
        let fm = FileManager.default, assetFolder = folder.appendingPathComponent("Assets")
        try fm.createDirectory(at:assetFolder,withIntermediateDirectories:true)
        for (name,data) in assets {
            guard name == URL(fileURLWithPath:name).lastPathComponent else { throw FolioError(message:"图片名称无效") }
            let file = assetFolder.appendingPathComponent(name)
            if fm.fileExists(atPath:file.path) {
                guard try Data(contentsOf:file) == data else { throw FolioError(message:"已有摘录图片与待保存内容不一致，应急副本可保留当前图片") }
            } else { try data.write(to:file,options:.atomic) }
            guard try Data(contentsOf:file) == data else { throw FolioError(message:"摘录图片保存后校验失败") }
        }
        if dailyChecked.map({ !Calendar.current.isDateInToday($0) }) ?? true {
            do {
                let previous = try? ReadingDeltaStorage.read(folder).state
                let daily = previous.flatMap { $0.records.isEmpty && $0.essays.isEmpty ? nil : $0 } ?? state
                try ReadingBackupStorage.daily(daily,folder:folder); dailyChecked = Date(); backupError = nil
            } catch { backupError = error.localizedDescription }
        }
        try ReadingDeltaStorage.locked(folder) {
            try ReadingUpgradeReceipt053.ensure(folder)
            if incremental { incrementalCache = try ReadingDeltaStorage.append(state,folder:folder,cached:incrementalCache) }
            else {
                let previous=try ReadingDeltaStorage.read(folder).state
                try ReadingRecordHistory.store(changed:state.records,essays:state.essays,previous:previous,folder:folder)
                try ReadingDeltaStorage.checkpoint(state,folder:folder);incrementalCache=try ReadingDeltaStorage.read(folder)
            }
        }
        latest = revision
        await ReadingMirrorWriter053.shared.schedule(state,folder:folder)
    }
}
@MainActor final class ReadingJournal: ObservableObject {
    @Published private(set) var state = ReadingJournalState()
    // Empty editors are transient. Only meaningful input promotes them into the catalog.
    @Published private(set) var draftRecord: ReadingRecord?
    @Published private(set) var draftEssay: ReadingEssay?
    @Published var pdfCaptureMessage:String?
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    @Published private(set) var lastVerifiedSave:Date?
    @Published private(set) var backupError:String?
    @Published private(set) var restoring = false
    @Published private(set) var dirty = false
    private(set) var unreadable = false
    let folder: URL
    private let writer = ReadingJournalWriter()
    private var revision = 0
    var revisionID:Int { revision }
    private var savedRevision = 0
    private var pendingAssets: [String:Data] = [:]
    var pendingImages:[String:Data] { pendingAssets }
    private var timer: Task<Void,Never>?
    private var worker: Task<Void,Error>?
    init(storage:URL) {
        folder = storage.appendingPathComponent("ReadingJournal",isDirectory:true)
        let file = folder.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath:file.path) || FileManager.default.fileExists(atPath:folder.appendingPathComponent("head053.json").path) else { return }
        do { let value = try ReadingDeltaStorage.read(folder).state; try value.validate(); state = value }
        catch { unreadable = true; self.error = "阅读记录未能读取，原记录保留：" + error.localizedDescription }
        if !unreadable { let snapshot = state, destination = folder; Task { [weak self] in
            do { try await self?.writer.ensureDaily(snapshot,folder:destination) } catch { self?.backupError = error.localizedDescription }
        } }
    }
    func record(_ id:UUID?) -> ReadingRecord? { if let draftRecord, draftRecord.id == id { return draftRecord }; return state.records.first { $0.id == id } }
    func essay(_ id:UUID?) -> ReadingEssay? { if let draftEssay, draftEssay.id == id { return draftEssay }; return state.essays.first { $0.id == id } }
    var currentEssayID: UUID? { draftEssay?.id ?? state.currentEssay }
    func beginNote(_ record: ReadingRecord) { guard !unreadable else { return }; draftRecord = record }
    func discardNoteDraft() { draftRecord = nil }
    func discardEssayDraft() { draftEssay = nil }
    func assetURL(_ name:String) -> URL { folder.appendingPathComponent("Assets").appendingPathComponent(name) }
    func stageAsset053(_ data:Data)throws->String {
        guard let decoded=SignatureImage.loadData(data),let bytes=SignatureImage.pngData(decoded) else { throw FolioError(message:"资料图片无法读取") }
        let name=OCRPageCache.digest(bytes)+".png";pendingAssets[name]=bytes;return name
    }
    @Published var bulkCheckpoint:ReadingBulkCheckpoint?
    var saveStatus:String { error ?? (saving ? "正在保存记录…" : (dirty ? "等待保存…" : (draftRecord != nil || draftEssay != nil ? "空白草稿：输入内容后自动保存，不计入记录" : "记录已自动保存"))) }
    func change(_ operation:(inout ReadingJournalState)->Void) {
        guard !unreadable else { return }
        operation(&state); revision += 1; dirty = true
        timer?.cancel(); timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:250_000_000) } catch { return }
            guard let self else { return }; do { try await self.flush(compatibilityCheckpoint:false) } catch { self.error = "阅读记录尚未保存：" + error.localizedDescription }
        }
    }
    @discardableResult func add(_ record:ReadingRecord,image:Data? = nil) -> UUID {
        guard !unreadable else { return record.id }
        var record = record
        if let image { let name = OCRPageCache.digest(image)+".png"; pendingAssets[name] = image; record.imageAsset = name }
        if record.kind == .note && !record.hasContent { beginNote(record); return record.id }
        if draftRecord?.id == record.id { draftRecord = nil }
        change { value in
            if let index = value.records.firstIndex(where:{$0.id == record.id}) { value.records[index] = record } else { value.records.append(record) }
            for citation in record.citations { value.lastNotes[citation.source.path] = record.id }
        }
        return record.id
    }
    func editRecord(_ id:UUID,_ edit:(inout ReadingRecord)->Void) {
        guard !unreadable else { return }
        if var draft = draftRecord, draft.id == id {
            edit(&draft); draft.modified = Date(); draftRecord = draft
            if draft.hasContent { add(draft) }
            return
        }
        guard let i = state.records.firstIndex(where:{$0.id == id}) else { return }
        change { value in edit(&value.records[i]); value.records[i].modified = Date(); for citation in value.records[i].citations { value.lastNotes[citation.source.path] = id } }
    }
    @discardableResult func newEssay(title:String = "未命名笔记") -> UUID {
        let essay = ReadingEssay(title:title)
        guard !unreadable else { return essay.id }
        if !essay.hasContent { draftEssay = essay; return essay.id }
        draftEssay = nil
        change { $0.essays.append(essay); $0.currentEssay = essay.id }; return essay.id
    }
    func editEssay(_ id:UUID,_ edit:(inout ReadingEssay)->Void) {
        guard !unreadable else { return }
        if var draft = draftEssay, draft.id == id {
            edit(&draft); draft.modified = Date(); draftEssay = draft
            if draft.hasContent { draftEssay = nil; change { $0.essays.append(draft); $0.currentEssay = id } }
            return
        }
        guard let i = state.essays.firstIndex(where:{$0.id == id}) else { return }
        change { value in edit(&value.essays[i]); value.essays[i].modified = Date() }
    }
    @discardableResult func insert(_ record:ReadingRecord,in essay:UUID,after block:UUID? = nil,at selection:NSRange? = nil) -> UUID {
        let id = UUID()
        editEssay(essay) { value in
            guard let block,let i = value.blocks.firstIndex(where:{$0.id == block}) else { value.blocks.append(ReadingEssay.Block(id:id,record:record));return }
            let ns = value.blocks[i].text as NSString
            let split = min(ns.length,selection.map{NSMaxRange(MarkdownNote.clamp($0,to:ns.length))} ?? ns.length)
            let safe = split == ns.length ? split : ns.rangeOfComposedCharacterSequence(at:split).location
            let tail = ns.substring(from:safe);value.blocks[i].text = ns.substring(to:safe)
            value.blocks.insert(ReadingEssay.Block(id:id,text:tail,record:record),at:i+1)
        };return id
    }
    func selectEssay(_ id:UUID) {
        guard draftEssay?.id != id, state.essays.contains(where: { $0.id == id }) else { return }
        draftEssay = nil
        guard state.currentEssay != id else { return }; change { $0.currentEssay = id }
    }
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
    func flush(compatibilityCheckpoint:Bool = true) async throws {
        timer?.cancel(); timer = nil
        if unreadable { throw FolioError(message:error ?? "阅读记录无法读取") }
        while let worker { try await worker.value; await Task.yield() }
        guard savedRevision != revision || !pendingAssets.isEmpty || (compatibilityCheckpoint && FileManager.default.fileExists(atPath:folder.appendingPathComponent("head053.json").path)) else { return }
        saving = true
        let value = state, number = revision, assets = pendingAssets, destination = folder, writer = writer
        let task = Task { try await writer.write(value,revision:number,assets:assets,folder:destination,incremental:!compatibilityCheckpoint) }
        worker = task
        do {
            try await task.value
            backupError = await writer.backupError
            worker = nil; savedRevision = number; for name in assets.keys { pendingAssets[name] = nil }
            dirty = revision != number; error = nil; saving = false;lastVerifiedSave = Date()
        } catch { worker = nil; saving = false; dirty = true; self.error = "阅读记录尚未保存：" + error.localizedDescription; throw error }
        if dirty { try await flush(compatibilityCheckpoint:compatibilityCheckpoint) }
    }
    func waitForMaintenance() async { while restoring { try? await Task.sleep(nanoseconds:20_000_000) } }
    func makeBackup() async throws -> ReadingBackup {
        try await flush(); let value = try await writer.checkpoint(state,folder:folder,kind:.manual); backupError = nil; return value
    }
    func restoreBackup(_ id:String,ids:Set<ReadingLibraryID>) async throws {
        guard !unreadable, !restoring else { throw FolioError(message:"请等待当前恢复完成，或先处理记录读取问题") }
        restoring = true; defer { restoring = false }
        try await flush(); let before = revision, destination = folder
        let transfer = try await Task.detached(priority:.userInitiated) { try ReadingBackupStorage.selection(id,ids:ids,folder:destination) }.value
        guard revision == before else { throw FolioError(message:"记录刚有更改，请重新预览后恢复") }
        _ = try await writer.checkpoint(state,folder:folder,kind:.beforeRestore)
        guard revision == before else { throw FolioError(message:"记录刚有更改，请重新预览后恢复") }
        pendingAssets.merge(transfer.assets) { old,_ in old }
        change { value in
            for record in transfer.state.records { if let i = value.records.firstIndex(where:{$0.id == record.id}) { value.records[i] = record } else { value.records.append(record) } }
            for essay in transfer.state.essays { if let i = value.essays.firstIndex(where:{$0.id == essay.id}) { value.essays[i] = essay } else { value.essays.append(essay) } }
        }
        try await flush()
    }
    func recoverPrevious() throws {
        let fm = FileManager.default, old = folder.appendingPathComponent("catalog.previous.json"), file = folder.appendingPathComponent("catalog.json")
        let bytes = try Data(contentsOf:old), recovered = try JSONDecoder().decode(ReadingJournalState.self,from:bytes); try recovered.validate()
        if fm.fileExists(atPath:file.path) { try fm.copyItem(at:file,to:folder.appendingPathComponent("catalog.damaged-"+UUID().uuidString+".json")) }
        try ReadingDeltaStorage.checkpoint(recovered,folder:folder); state = recovered; unreadable = false; error = nil
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
        guard FileManager.default.fileExists(atPath:file.path) || FileManager.default.fileExists(atPath:folder.appendingPathComponent("head053.json").path) else { return nil }
        let state = try ReadingDeltaStorage.read(folder).state; try state.validate()
        var assets:[String:Data] = [:]
        for name in state.assetNames053 { try Task.checkCancellation(); assets[name] = try Data(contentsOf:folder.appendingPathComponent("Assets").appendingPathComponent(name),options:.mappedIfSafe) }
        return Self(state:state,assets:assets)
    }
}

extension ReadingEssay {
    mutating func move(_ id:UUID,before destination:UUID) {
        guard id != destination,let from = blocks.firstIndex(where:{$0.id == id}),blocks.contains(where:{$0.id == destination}) else { return }
        let block = blocks.remove(at:from);if let to = blocks.firstIndex(where:{$0.id == destination}) { blocks.insert(block,at:to) }
    }
}

extension ReadingJournal {
    func restoreParagraph(_ backupID:String,item:ReadingLibraryID,index:Int,expected:ReadingJournalState) async throws {
        guard state == expected,!restoring,!unreadable else { throw FolioError(message:"正文已变化，请刷新对照后恢复") }
        restoring = true;defer { restoring = false }
        let backup = try await Task.detached { try ReadingBackupStorage.read(backupID,folder:self.folder) }.value
        let parts = ReadingVersionCompare.paragraphs(item,state:backup.state)
        guard parts.indices.contains(index),state == expected else { throw FolioError(message:"段落已变化，请重新核对") }
        _ = try await makeBackup()
        guard state == expected else { throw FolioError(message:"正文已变化，请重新核对") }
        let paragraph = parts[index]
        switch item {
        case .record(let id):
            guard record(id)?.removed == nil,state.records.contains(where:{$0.id == id}) else { throw FolioError(message:"请先恢复完整记录") }
            editRecord(id) { value in var current = value.note.components(separatedBy:"\n\n");if index<current.count { current[index] = paragraph } else { current.append(paragraph) };value.note = current.joined(separator:"\n\n") }
        case .essay(let id):
            guard let saved = backup.state.essays.first(where:{$0.id == id}),saved.blocks.indices.contains(index),let live = essay(id),live.removed == nil,let target = live.blocks.firstIndex(where:{$0.id == saved.blocks[index].id}) else { throw FolioError(message:"该段落已被移除，请使用完整记录恢复") }
            editEssay(id) { $0.blocks[target].text = paragraph }
        }
        try await flush()
    }
}
