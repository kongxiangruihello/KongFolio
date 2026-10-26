import Foundation
import CryptoKit
import PDFKit

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var created: Date
    var pages: Int
    var label: String
    var digest: String
    var diskDigest: String
    var bytes: Int
    var automatic: Bool
    var groupStarted: Date? = nil
}

/// One bounded timeline per original file. Payloads and indexes commit atomically before old versions are pruned.
enum DocumentHistory {
    static let maximumEntries = 10
    static let byteBudget = 512 * 1024 * 1024
    static let coalescingSeconds: TimeInterval = 60
    private static let queue = DispatchQueue(label: "com.kongfolio.history")
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    static func folder(for source: URL, storage: URL) -> URL {
        storage.appendingPathComponent("History", isDirectory:true).appendingPathComponent(hash(Data(source.standardizedFileURL.path.utf8)), isDirectory:true)
    }
    private static func entries(in directory: URL) throws -> [HistoryEntry] {
        let url = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        return try JSONDecoder().decode([HistoryEntry].self,from:Data(contentsOf:url))
    }
    static func list(source: URL, storage: URL) throws -> [HistoryEntry] {
        try queue.sync { try entries(in:folder(for:source,storage:storage)).reversed() }
    }
    static func read(_ entry: HistoryEntry, source: URL, storage: URL) throws -> ProjectArchive {
        try queue.sync {
            let directory = folder(for:source,storage:storage)
            guard try entries(in:directory).contains(where:{$0.id == entry.id}) else { throw FolioError(message:"这个版本已不在历史中。") }
            let data = try Data(contentsOf:directory.appendingPathComponent(entry.id.uuidString+".kongfolio"))
            guard hash(data) == entry.digest else { throw FolioError(message:"这个历史版本校验失败，未恢复。") }
            let archive = try ProjectContainer.decode(data);try archive.validate();return archive
        }
    }
    /// Before any overwrite, keep the current on-disk state unless it is already the newest history version.
    static func protectExisting(_ source: URL, storage: URL) throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath:source.path) else { return }
            let bytes = try Data(contentsOf:source,options:.mappedIfSafe)
            let diskDigest = hash(bytes)
            let directory = folder(for:source,storage:storage)
            if let last = try entries(in:directory).last, last.diskDigest == diskDigest,
               let payload = try? Data(contentsOf:directory.appendingPathComponent(last.id.uuidString+".kongfolio")), hash(payload) == last.digest { return }
            let archive: ProjectArchive
            if source.pathExtension.lowercased() == "kongfolio" { archive = try ProjectArchive.read(source) }
            else {
                guard let doc = PDFDocument(data:bytes), !doc.isLocked, doc.pageCount > 0 else { throw FolioError(message:"原文件无法读取，未覆盖；请另存到新位置。") }
                archive = ProjectArchive(reading:ReadingState(outline:ReadingServices.outline(doc)),sourcePath:source.path,pdf:bytes,title:source.deletingPathExtension().lastPathComponent,selection:0,selectedPages:[0],mode:.document,recipes:[:],drafts:[:],dirty:false,projectPath:nil)
            }
            try recordUnlocked(archive,source:source,storage:storage,label:"首次保存前 / 外部修改前的原件",automatic:false,diskDigest:diskDigest,now:Date())
        }
    }
    static func record(_ archive: ProjectArchive, source: URL, storage: URL, label: String = "自动保存", automatic: Bool = true, now: Date = Date()) throws {
        try queue.sync {
            let diskDigest = try hash(Data(contentsOf:source,options:.mappedIfSafe))
            try recordUnlocked(archive,source:source,storage:storage,label:label,automatic:automatic,diskDigest:diskDigest,now:now)
        }
    }
    private static func recordUnlocked(_ archive: ProjectArchive, source: URL, storage: URL, label: String, automatic: Bool, diskDigest: String, now: Date) throws {
        try archive.validate()
        let directory = folder(for:source,storage:storage)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var stored = try entries(in:directory)
        let data = try ProjectContainer.encode(archive), digest = hash(data)
        // Compare semantic state, since JSON dictionary ordering may differ between encodings.
        if let last = stored.last, last.diskDigest == diskDigest,
           let previousData = try? Data(contentsOf:directory.appendingPathComponent(last.id.uuidString+".kongfolio")), hash(previousData) == last.digest,
           let previous = try? ProjectArchive.read(directory.appendingPathComponent(last.id.uuidString+".kongfolio")),
           previous.pdf == archive.pdf,
           (try? JSONEncoder.sorted.encode(previous.reading)) == (try? JSONEncoder.sorted.encode(archive.reading)),
           previous.ocrOriginals == archive.ocrOriginals, previous.ocrRegions == archive.ocrRegions { return }
        var entry = HistoryEntry(id:UUID(),created:now,pages:PDFDocument(data:archive.pdf)?.pageCount ?? 0,label:label,digest:digest,diskDigest:diskDigest,bytes:data.count,automatic:automatic)
        let previousEntries = stored
        entry.groupStarted = now
        if automatic, stored.count >= 2, let last = stored.last, last.automatic,
           now.timeIntervalSince(last.groupStarted ?? last.created) >= 0,
           now.timeIntervalSince(last.groupStarted ?? last.created) < coalescingSeconds {
            entry.groupStarted = last.groupStarted ?? last.created
            stored.removeLast()
        }
        stored.append(entry)
        while stored.count > maximumEntries || (stored.count > 2 && stored.reduce(0,{$0+$1.bytes}) > byteBudget) { stored.removeFirst() }
        let payload = directory.appendingPathComponent(entry.id.uuidString+".kongfolio")
        try data.write(to:payload,options:.atomic)
        do { try JSONEncoder().encode(stored).write(to:directory.appendingPathComponent("index.json"),options:.atomic) }
        catch { try? FileManager.default.removeItem(at:payload); throw error }
        let live = Set(stored.map(\.id))
        for old in previousEntries where !live.contains(old.id) { try? FileManager.default.removeItem(at:directory.appendingPathComponent(old.id.uuidString+".kongfolio")) }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return e }
}

extension Workspace {
    var historySource: URL? { projectURL ?? (sourceURL?.pathExtension.lowercased() == "pdf" ? sourceURL : nil) }
    @discardableResult func restoreVersion(_ entry: HistoryEntry) -> Bool {
        guard !busy, let source=historySource else { return false }
        do {
            let archived = try DocumentHistory.read(entry,source:source,storage:storage)
            // Record unsaved work too, so restoration itself can be reversed after closing the app.
            try DocumentHistory.record(snapshot(),source:source,storage:storage,label:"恢复历史前的当前工作",automatic:false)
            checkpoint()
            try restore(archived,keepProjectURL:true)
            readingPoint=nil;navigationToken=UUID();edited(reset:true)
            return saveDirectly(askForDestination:false)
        } catch { self.error="无法恢复历史版本：\(error.localizedDescription)";return false }
    }
}
