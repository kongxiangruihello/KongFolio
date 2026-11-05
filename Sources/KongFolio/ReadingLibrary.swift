import Foundation

enum ReadingLibraryID: Hashable { case record(UUID), essay(UUID) }
enum ReadingLibraryItem: Identifiable {
    case record(ReadingRecord), essay(ReadingEssay)
    var id:ReadingLibraryID { switch self { case .record(let r): .record(r.id); case .essay(let e): .essay(e.id) } }
    var title:String { switch self { case .record(let r): r.displayTitle; case .essay(let e): e.title } }
    var kind:String { switch self { case .record(let r): r.kind.rawValue; case .essay: "笔记" } }
    var tags:[String] { switch self { case .record(let r): r.tags; case .essay(let e): e.tags } }
    var created:Date { switch self { case .record(let r): r.created; case .essay(let e): e.created } }
    var key:String { switch self { case .record(let r): "r:"+r.id.uuidString; case .essay(let e): "e:"+e.id.uuidString } }
    static func results(_ state:ReadingJournalState,query:String = "",kind:String = "全部",tag:String = "",removed:Bool = false) -> [Self] {
        let records = state.records.filter { !Task.isCancelled && $0.hasContent && ($0.removed != nil) == removed && (kind == "全部" || $0.kind.rawValue == kind || (kind == "摘录" && $0.kind == .image)) && $0.matches(query,tag:tag) }.map(Self.record)
        let essays = state.essays.filter { !Task.isCancelled && $0.hasContent && ($0.removed != nil) == removed && (kind == "全部" || kind == "札记" || kind == "笔记") && (tag.isEmpty || $0.tags.contains(tag)) && $0.matches(query) }.map(Self.essay)
        return (records+essays).sorted { $0.created == $1.created ? $0.key < $1.key : $0.created > $1.created }
    }
}
extension ReadingJournal {
    func setRemoved(_ ids:Set<ReadingLibraryID>,removed:Bool) {
        let beforeBulk = state
        defer { finishBulk(beforeBulk,"批量删除或恢复") }
        guard !unreadable, !ids.isEmpty else { return }
        let date:Date? = removed ? Date() : nil
        change { state in
            for i in state.records.indices where ids.contains(.record(state.records[i].id)) { state.records[i].removed = date }
            for i in state.essays.indices where ids.contains(.essay(state.essays[i].id)) { state.essays[i].removed = date; if removed && state.currentEssay == state.essays[i].id { state.currentEssay = nil } }
        }
    }
}

extension ReadingLibraryItem {
    func isFromBook(_ path:String)->Bool {
        let target = ReadingBookIdentity.key(path)
        switch self {
        case .record(let r):return r.citations.contains{ReadingBookIdentity.key($0.source.path) == target}
        case .essay(let e):return e.blocks.contains{$0.record?.citations.contains{ReadingBookIdentity.key($0.source.path) == target} == true}
        }
    }
}

/// Foundation can spell the same macOS temporary file as /tmp or /private/tmp.
/// Match built-in aliases without probing every source file during a search.
enum ReadingBookIdentity {
    static func key(_ path:String)->String {
        guard !path.isEmpty else { return "" }
        let value = URL(fileURLWithPath:path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
        for root in ["tmp","var","etc"] {
            let prefix = "/private/"+root
            if value == prefix || value.hasPrefix(prefix+"/") { return String(value.dropFirst("/private".count)) }
        }
        return value
    }
}

@MainActor extension ReadingJournal {
    func beginLibraryRecord(_ kind:ReadingRecord.Kind,source:ReadingCitation? = nil)->ReadingRecord {
        let record = ReadingRecord(kind:kind,citations:source.map{[$0]} ?? [],wholeBook:source != nil)
        beginNote(record)
        return record
    }
    func beginLibraryEssay(source:ReadingCitation? = nil)->UUID {
        let id = newEssay()
        if let source { editEssay(id) { value in
            if !value.blocks.isEmpty { value.blocks[0].record = ReadingRecord(kind:.note,citations:[source],wholeBook:true) }
        } }
        return id
    }
}
