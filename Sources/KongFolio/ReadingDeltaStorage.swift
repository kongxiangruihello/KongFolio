import Foundation
import Darwin

/// The legacy catalog is a compatible checkpoint. Automatic saves append verified, atomic deltas.
/// An interrupted append cannot invalidate the preceding committed transaction.
enum ReadingDeltaStorage {
    struct Head:Codable { var generation:String;var digest:String }
    struct Envelope:Codable { var payload:Data;var checksum:String }
    struct Delta:Codable {
        var sequence:Int
        var parent:String
        var records:[ReadingRecord]
        var essays:[ReadingEssay]
        var removedRecords:[UUID]
        var removedEssays:[UUID]
        var recordOrder:[UUID]?
        var essayOrder:[UUID]?
        var currentEssay:UUID?
        var lastNotes:[String:UUID]
        var deletedNotes:[String]
        var date:Date
    }
    struct Loaded { var state:ReadingJournalState;var sequence:Int;var digest:String;var generation:String }
    static func locked<T>(_ folder:URL,_ body:()throws->T)throws->T {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let fd=open(folder.appendingPathComponent("writer053.lock").path,O_CREAT|O_RDWR,S_IRUSR|S_IWUSR)
        guard fd>=0 else { throw FolioError(message:"无法锁定阅读资料保存目录") }
        defer { close(fd) }
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else { throw FolioError(message:"另一份应用正在保存阅读资料，请稍后重试") }
        defer { flock(fd,LOCK_UN) };return try body()
    }
    static func active(_ folder:URL)throws->URL {
        let head=folder.appendingPathComponent("head053.json")
        guard FileManager.default.fileExists(atPath:head.path) else { return folder }
        let name=try JSONDecoder().decode(Head.self,from:Data(contentsOf:head)).generation
        guard UUID(uuidString:name) != nil else { throw FolioError(message:"阅读记录快照编号无效") }
        return folder.appendingPathComponent("Generations053").appendingPathComponent(name)
    }
    static func read(_ folder:URL)throws->Loaded {
        let fm=FileManager.default,base=try active(folder),file=base.appendingPathComponent("catalog.json")
        if base != folder && !fm.fileExists(atPath:file.path) { throw FolioError(message:"阅读记录完整快照缺失，原文件已保留") }
        let bytes=try fm.fileExists(atPath:file.path) ? Data(contentsOf:file) : JSONEncoder().encode(ReadingJournalState())
        if base != folder {
            let head=try JSONDecoder().decode(Head.self,from:Data(contentsOf:folder.appendingPathComponent("head053.json")))
            guard head.digest==OCRPageCache.digest(bytes) else { throw FolioError(message:"阅读资料完整快照校验不符，原文件已保留") }
            let legacy=folder.appendingPathComponent("catalog.json")
            if fm.fileExists(atPath:legacy.path) {
                let digest=OCRPageCache.digest(try Data(contentsOf:legacy))
                let previous=(try? Data(contentsOf:folder.appendingPathComponent("head053.previous.json"))).flatMap{try? JSONDecoder().decode(Head.self,from:$0)}
                guard digest==head.digest || digest==previous?.digest else { throw FolioError(message:"兼容快照已在外部改动或损坏，请核对恢复；原文件已保留") }
            }
        }
        var state=try JSONDecoder().decode(ReadingJournalState.self,from:bytes)
        try state.validate()
        var digest=OCRPageCache.digest(bytes),sequence=0
        let directory=base.appendingPathComponent("Transactions")
        let files=(try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil))?.filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent} ?? []
        for file in files {
            let data=try Data(contentsOf:file),envelope=try JSONDecoder().decode(Envelope.self,from:data)
            guard envelope.checksum==OCRPageCache.digest(envelope.payload) else { throw FolioError(message:"阅读记录增量校验失败，原文件已保留") }
            let delta=try JSONDecoder().decode(Delta.self,from:envelope.payload)
            // A checkpoint receipt makes completed compaction distinguishable from corruption.
            guard delta.sequence==sequence+1,Set(delta.records.map(\.id)).count==delta.records.count,Set(delta.essays.map(\.id)).count==delta.essays.count else { throw FolioError(message:"阅读记录增量编号冲突，原文件已保留") }
            guard delta.parent==digest else { throw FolioError(message:"阅读记录增量链不完整，原文件已保留，请从完整快照恢复") }
            try apply(delta,to:&state);try state.validate();sequence=delta.sequence;digest=OCRPageCache.digest(data)
        }
        return Loaded(state:state,sequence:sequence,digest:digest,generation:base.lastPathComponent)
    }
    static func apply(_ d:Delta,to s:inout ReadingJournalState) throws {
        let r=Dictionary(uniqueKeysWithValues:d.records.map{($0.id,$0)}),e=Dictionary(uniqueKeysWithValues:d.essays.map{($0.id,$0)})
        let oldR=Set(s.records.map(\.id)),oldE=Set(s.essays.map(\.id))
        s.records=s.records.filter{!d.removedRecords.contains($0.id)}.map{r[$0.id] ?? $0}+d.records.filter{!oldR.contains($0.id)}
        s.essays=s.essays.filter{!d.removedEssays.contains($0.id)}.map{e[$0.id] ?? $0}+d.essays.filter{!oldE.contains($0.id)}
        if let order=d.recordOrder { guard Set(order)==Set(s.records.map(\.id)),Set(order).count==order.count else { throw FolioError(message:"记录顺序无效") };let values=Dictionary(uniqueKeysWithValues:s.records.map{($0.id,$0)});s.records=order.compactMap{values[$0]} }
        if let order=d.essayOrder { guard Set(order)==Set(s.essays.map(\.id)),Set(order).count==order.count else { throw FolioError(message:"笔记顺序无效") };let values=Dictionary(uniqueKeysWithValues:s.essays.map{($0.id,$0)});s.essays=order.compactMap{values[$0]} }
        s.currentEssay=d.currentEssay
        for key in d.deletedNotes { s.lastNotes[key]=nil };s.lastNotes.merge(d.lastNotes){_,new in new}
    }
    static func append(_ state:ReadingJournalState,folder:URL,cached:Loaded? = nil) throws -> Loaded {
        let fm=FileManager.default,base=try active(folder),file=base.appendingPathComponent("catalog.json")
        if !fm.fileExists(atPath:file.path) { try checkpoint(state,folder:folder);return try read(folder) }
        if let cached,cached.generation != base.lastPathComponent { throw FolioError(message:"阅读资料已由另一个窗口或进程更新，请先保留当前版本") }
        let loaded=try cached ?? read(folder),old=loaded.state
        guard old != state else { return loaded }
        let oldR=Dictionary(uniqueKeysWithValues:old.records.map{($0.id,$0)}),oldE=Dictionary(uniqueKeysWithValues:old.essays.map{($0.id,$0)})
        let records=state.records.filter{oldR[$0.id] != $0},essays=state.essays.filter{oldE[$0.id] != $0}
        let newR=Set(state.records.map(\.id)),newE=Set(state.essays.map(\.id))
        let d=Delta(sequence:loaded.sequence+1,parent:loaded.digest,records:records,essays:essays,removedRecords:old.records.map(\.id).filter{!newR.contains($0)},removedEssays:old.essays.map(\.id).filter{!newE.contains($0)},recordOrder:old.records.map(\.id)==state.records.map(\.id) ? nil:state.records.map(\.id),essayOrder:old.essays.map(\.id)==state.essays.map(\.id) ? nil:state.essays.map(\.id),currentEssay:state.currentEssay,lastNotes:state.lastNotes.filter{old.lastNotes[$0.key] != $0.value},deletedNotes:old.lastNotes.keys.filter{state.lastNotes[$0]==nil},date:Date())
        try ReadingRecordHistory.store(changed:records,essays:essays,previous:old,folder:folder)
        let directory=base.appendingPathComponent("Transactions");try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let payload=try JSONEncoder().encode(d),data=try JSONEncoder().encode(Envelope(payload:payload,checksum:OCRPageCache.digest(payload))),target=directory.appendingPathComponent(String(format:"%012d",d.sequence)+".json")
        guard !fm.fileExists(atPath:target.path) else { throw FolioError(message:"另一个进程已保存阅读记录，请先备份当前内容") }
        try data.write(to:target,options:.atomic)
        guard try Data(contentsOf:target)==data else { throw FolioError(message:"增量记录保存后核验失败") }
        if d.sequence>=256 { try checkpoint(state,folder:folder);return try read(folder) }
        return Loaded(state:state,sequence:d.sequence,digest:OCRPageCache.digest(data),generation:base.lastPathComponent)
    }
    static func checkpoint(_ state:ReadingJournalState,folder:URL) throws {
        try state.validate();let fm=FileManager.default
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let file=folder.appendingPathComponent("catalog.json"),head=folder.appendingPathComponent("head053.json")
        let data=try JSONEncoder().encode(state)
        let generations=folder.appendingPathComponent("Generations053"),name=UUID().uuidString,next=generations.appendingPathComponent(name)
        try fm.createDirectory(at:next,withIntermediateDirectories:true)
        let staged=next.appendingPathComponent("catalog.json");try data.write(to:staged,options:.atomic)
        guard try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:staged))==state else { throw FolioError(message:"完整阅读快照核验失败") }
        // Commit one small pointer only after the entire new generation is durable. Old generations
        // remain valid during every intermediate step, including process interruption.
        if fm.fileExists(atPath:head.path) { try Data(contentsOf:head).write(to:folder.appendingPathComponent("head053.previous.json"),options:.atomic) }
        try JSONEncoder().encode(Head(generation:name,digest:OCRPageCache.digest(data))).write(to:head,options:.atomic)
        if fm.fileExists(atPath:file.path),let old=try? Data(contentsOf:file),let decoded=try? JSONDecoder().decode(ReadingJournalState.self,from:old),(try? decoded.validate()) != nil { try old.write(to:folder.appendingPathComponent("catalog.previous.json"),options:.atomic) }
        try data.write(to:file,options:.atomic)
        guard try Data(contentsOf:file)==data else { throw FolioError(message:"兼容阅读快照核验失败") }
        let previous=(try? Data(contentsOf:folder.appendingPathComponent("head053.previous.json"))).flatMap{try? JSONDecoder().decode(Head.self,from:$0)}?.generation
        for old in (try? fm.contentsOfDirectory(at:generations,includingPropertiesForKeys:nil)) ?? [] where UUID(uuidString:old.lastPathComponent) != nil && old.lastPathComponent != name && old.lastPathComponent != previous { try? fm.removeItem(at:old) }
    }
}

enum ReadingRecordHistory {
    struct Revision:Codable,Identifiable {
        var id=UUID();var date=Date();var record:ReadingRecord?;var essay:ReadingEssay?
        var title:String { record?.displayTitle ?? essay?.title ?? "笔记" }
    }
    static func directory(_ key:String,folder:URL)->URL { folder.appendingPathComponent("History053").appendingPathComponent(key) }
    static func store(changed:[ReadingRecord],essays:[ReadingEssay],previous:ReadingJournalState,folder:URL) throws {
        let previousRecords=Dictionary(uniqueKeysWithValues:previous.records.map{($0.id,$0)}),previousEssays=Dictionary(uniqueKeysWithValues:previous.essays.map{($0.id,$0)})
        func save(_ revision:Revision,key:String) throws {
            let folder=directory(key,folder:folder),fm=FileManager.default;try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            // Coalesce autosaves within a minute; preserve the version before that minute's first edit.
            let file=folder.appendingPathComponent(String(format:"%012.0f",floor(Date().timeIntervalSince1970/60))+"-snapshot.json")
            if fm.fileExists(atPath:file.path) { return }
            let data=try JSONEncoder().encode(revision);try data.write(to:file,options:.atomic)
            let files=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey]).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent>$1.lastPathComponent}
            var size=0
            for (i,f) in files.enumerated() { size += (try f.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0;if i>=200 || (size>32*1024*1024 && i>1) { try fm.removeItem(at:f) } }
        }
        for r in changed { if let old=previousRecords[r.id],old != r { try save(Revision(record:old),key:"r-"+r.id.uuidString) } }
        for e in essays { if let old=previousEssays[e.id],old != e { try save(Revision(essay:old),key:"e-"+e.id.uuidString) } }
    }
    static func read(_ key:String,folder:URL)throws->[Revision] {
        let f=directory(key,folder:folder);guard FileManager.default.fileExists(atPath:f.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:f,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent>$1.lastPathComponent}.map{try JSONDecoder().decode(Revision.self,from:Data(contentsOf:$0))}
    }
}
