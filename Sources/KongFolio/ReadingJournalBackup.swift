import Foundation
import PDFKit

struct ReadingBackup: Codable, Identifiable {
    enum Kind:String,Codable { case daily = "每日备份", manual = "手动备份", beforeRestore = "恢复前备份" }
    var version = 1
    var id = UUID().uuidString
    var date = Date()
    var kind:Kind
    var state:ReadingJournalState
    var assets:[String:String]
    var digest:String
}

enum ReadingBackupStorage {
    static func bytes(_ state:ReadingJournalState) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(state) }
    static func root(_ folder:URL) -> URL { folder.appendingPathComponent("Backups",isDirectory:true) }
    static func checked(_ url:URL) throws {
        guard url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path else { throw FolioError(message:"备份目录包含链接，已停止操作") }
    }
    static func file(_ id:String,folder:URL) throws -> URL {
        guard UUID(uuidString:id) != nil else { throw FolioError(message:"备份编号无效") }
        let url = root(folder).appendingPathComponent(id+".json"); try checked(url); return url
    }
    static func list(_ folder:URL) throws -> [ReadingBackup] {
        let base = root(folder); try checked(base)
        guard FileManager.default.fileExists(atPath:base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:nil).filter{$0.pathExtension == "json"}.compactMap { url in
            guard let id = UUID(uuidString:url.deletingPathExtension().lastPathComponent)?.uuidString else { return nil }
            return try? read(id,folder:folder)
        }.sorted { $0.date > $1.date }
    }
    static func read(_ id:String,folder:URL) throws -> ReadingBackup {
        let url = try file(id,folder:folder)
        let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 128*1024*1024 else { throw FolioError(message:"备份文件无效或过大") }
        let value = try JSONDecoder().decode(ReadingBackup.self,from:Data(contentsOf:url))
        try value.state.validate()
        guard value.version == 1, value.id == id, OCRPageCache.digest(try bytes(value.state)) == value.digest,
              value.assets.allSatisfy({ name,hash in name == URL(fileURLWithPath:name).lastPathComponent && !name.contains("..") && hash.count == 64 && hash.allSatisfy({$0.isASCII && $0.isHexDigit}) }) else { throw FolioError(message:"备份校验未通过，现有记录保持不变") }
        return value
    }
    @discardableResult static func capture(_ state:ReadingJournalState,folder:URL,kind:ReadingBackup.Kind,date:Date = Date()) throws -> ReadingBackup {
        try state.validate(); let fm = FileManager.default, base = root(folder), blobs = base.appendingPathComponent("Assets",isDirectory:true)
        try checked(base); try checked(blobs); try fm.createDirectory(at:blobs,withIntermediateDirectories:true)
        var assets:[String:String] = [:]
        for name in state.assetNames053 {
            let source = folder.appendingPathComponent("Assets").appendingPathComponent(name); try checked(source)
            let data = try Data(contentsOf:source), hash = OCRPageCache.digest(data), destination = blobs.appendingPathComponent(hash)
            try checked(destination)
            if fm.fileExists(atPath:destination.path) { guard OCRPageCache.digest(try Data(contentsOf:destination)) == hash else { throw FolioError(message:"已有备份图片校验失败，未覆盖") } }
            else { try data.write(to:destination,options:.atomic) }
            assets[name] = hash
        }
        let value = ReadingBackup(date:date,kind:kind,state:state,assets:assets,digest:OCRPageCache.digest(try bytes(state)))
        try JSONEncoder().encode(value).write(to:try file(value.id,folder:folder),options:.atomic)
        if kind == .daily {
            for old in try list(folder).filter({$0.kind == .daily}).dropFirst(30) { try fm.removeItem(at:try file(old.id,folder:folder)) }
        }
        return value
    }
    static func daily(_ state:ReadingJournalState,folder:URL,date:Date = Date()) throws {
        guard !state.records.isEmpty || !state.essays.isEmpty else { return }
        if try list(folder).contains(where:{$0.kind == .daily && Calendar.current.isDate($0.date,inSameDayAs:date)}) { return }
        try capture(state,folder:folder,kind:.daily,date:date)
    }
    static func selection(_ id:String,ids:Set<ReadingLibraryID>,folder:URL) throws -> ReadingJournalTransfer {
        let backup = try read(id,folder:folder)
        var records = backup.state.records.filter{ids.contains(.record($0.id))}, essays = backup.state.essays.filter{ids.contains(.essay($0.id))}
        guard !records.isEmpty || !essays.isEmpty else { throw FolioError(message:"请选择要恢复的记录") }
        var assets:[String:Data] = [:], names:[String:String] = [:]
        let imageNames = ReadingJournalState(records:records,essays:essays).assetNames053
        for name in imageNames {
            guard let hash = backup.assets[name] else { throw FolioError(message:"备份缺少图片，现有记录保持不变") }
            let file = root(folder).appendingPathComponent("Assets").appendingPathComponent(hash); try checked(file)
            let data = try Data(contentsOf:file); guard OCRPageCache.digest(data) == hash else { throw FolioError(message:"备份图片校验失败，现有记录保持不变") }
            // A restored image gets a content-derived name and never overwrites another live image.
            var restored = hash+".png"
            let live = folder.appendingPathComponent("Assets").appendingPathComponent(restored); try checked(live)
            if FileManager.default.fileExists(atPath:live.path), try Data(contentsOf:live) != data { restored = hash+"-restored-"+UUID().uuidString+".png" }
            names[name] = restored; assets[restored] = data
        }
        func remap(_ r:inout ReadingRecord) { r.remapAssets053(names) }
        for i in records.indices { remap(&records[i]); records[i].removed = nil; records[i].modified = Date() }
        for i in essays.indices { essays[i].removed = nil; essays[i].modified = Date();essays[i].extras?.remapAssets053(names); for j in essays[i].blocks.indices { if var r = essays[i].blocks[j].record { remap(&r); essays[i].blocks[j].record = r } } }
        return ReadingJournalTransfer(state:ReadingJournalState(records:records,essays:essays),assets:assets)
    }
}

extension ReadingJournalWriter {
    func ensureDaily(_ state:ReadingJournalState,folder:URL) throws { try ReadingBackupStorage.daily(state,folder:folder) }
    func checkpoint(_ state:ReadingJournalState,folder:URL,kind:ReadingBackup.Kind) throws -> ReadingBackup { try ReadingBackupStorage.capture(state,folder:folder,kind:kind) }
}

extension ReadingBackupStorage {
    /// Import an extracted emergency catalog as a previewable backup, without changing live records.
    static func importEmergency(_ source:URL,folder:URL) throws -> ReadingBackup {
        let catalog = source.appendingPathComponent("catalog.json");try checked(catalog)
        let attributes = try FileManager.default.attributesOfItem(atPath:catalog.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 128*1024*1024 else { throw FolioError(message:"应急目录记录过大") }
        guard let transfer = try ReadingJournalTransfer.read(source) else { throw FolioError(message:"请选择解压后的 ReadingJournal 目录") }
        let base = root(folder),blobs = base.appendingPathComponent("Assets",isDirectory:true);try checked(base);try checked(blobs);try FileManager.default.createDirectory(at:blobs,withIntermediateDirectories:true)
        var assets:[String:String] = [:]
        for (name,data) in transfer.assets { try Task.checkCancellation();let hash = OCRPageCache.digest(data),file = blobs.appendingPathComponent(hash);try checked(file);if FileManager.default.fileExists(atPath:file.path) { guard try Data(contentsOf:file) == data else { throw FolioError(message:"备份图片校验失败") } } else { try data.write(to:file,options:.atomic) };assets[name] = hash }
        let value = ReadingBackup(kind:.manual,state:transfer.state,assets:assets,digest:OCRPageCache.digest(try bytes(transfer.state)))
        try JSONEncoder().encode(value).write(to:try file(value.id,folder:folder),options:.atomic);return value
    }
}

struct ReadingBackupVerification {
    let excerpts: Int
    let notes: Int
    let otherRecords: Int
    let images: Int
    let links: Int
    let missingLinks: Int
    let cloudLinks: Int

    var summary: String {
        "试恢复通过 · 摘录 \(excerpts) 条 · 笔记 \(notes) 条 · 其他记录 \(otherRecords) 条 · 图片 \(images) 张 · 出处 \(links) 处"
        + (missingLinks > 0 ? " · \(missingLinks) 处原文缺失或页码失效" : "")
        + (cloudLinks > 0 ? " · \(cloudLinks) 处云端原文待下载" : "")
    }
}

extension ReadingBackupStorage {
    static func verifyRestore(_ id: String,folder: URL) throws -> ReadingBackupVerification {
        let backup = try read(id,folder:folder)
        let state = backup.state
        let isolated = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-restore-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:isolated) }
        let images = isolated.appendingPathComponent("Assets",isDirectory:true)
        try FileManager.default.createDirectory(at:images,withIntermediateDirectories:true)
        for name in state.assetNames053 {
            try Task.checkCancellation()
            guard let hash = backup.assets[name] else { throw FolioError(message:"试恢复失败：备份缺少图片 "+name) }
            let source = root(folder).appendingPathComponent("Assets").appendingPathComponent(hash)
            try checked(source)
            let bytes = try Data(contentsOf:source,options:.mappedIfSafe)
            guard OCRPageCache.digest(bytes) == hash, SignatureImage.loadData(bytes) != nil else {
                throw FolioError(message:"试恢复失败：图片校验未通过")
            }
            try bytes.write(to:images.appendingPathComponent(name),options:.atomic)
        }
        try ReadingDeltaStorage.checkpoint(state,folder:isolated)
        guard let restored = try ReadingJournalTransfer.read(isolated), restored.state == state,
              restored.assets.allSatisfy({ OCRPageCache.digest($0.value) == backup.assets[$0.key] }) else {
            throw FolioError(message:"试恢复后的记录或图片与备份不一致")
        }
        let items = state.records.map(ReadingLibraryItem.record) + state.essays.map(ReadingLibraryItem.essay)
        let citations = items.flatMap(\.citations053)
        var statuses: [String:ShelfFileStatus] = [:]
        var pageCounts: [String:Int] = [:]
        var missing = 0, cloud = 0
        for citation in citations {
            try Task.checkCancellation()
            let path = citation.source.path
            guard !path.isEmpty, citation.source.invalidPage053 != true else { missing += 1; continue }
            let status = statuses[path] ?? ShelfFileStatus.read(URL(fileURLWithPath:path))
            statuses[path] = status
            switch status {
            case .missing: missing += 1
            case .cloud: cloud += 1
            case .available:
                let url = URL(fileURLWithPath:path)
                guard ["pdf","kongfolio"].contains(url.pathExtension.lowercased()) else { continue }
                if pageCounts[path] == nil {
                    pageCounts[path] = autoreleasepool {
                        guard let document = ReadingSourceInput(url:url).document(), !document.isLocked else { return 0 }
                        return document.pageCount
                    }
                }
                if !(0..<(pageCounts[path] ?? 0)).contains(citation.source.page) { missing += 1 }
            }
        }
        let excerpts = state.records.filter(\.isExcerpt).count
        let recordNotes = state.records.filter { $0.kind == .note }.count
        return ReadingBackupVerification(excerpts:excerpts,notes:recordNotes+state.essays.count,
                                         otherRecords:state.records.count-excerpts-recordNotes,
                                         images:restored.assets.count,links:citations.count,missingLinks:missing,cloudLinks:cloud)
    }
}
