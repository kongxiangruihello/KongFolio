import Foundation

enum ReadingLibraryID: Hashable { case record(UUID), essay(UUID) }
enum ReadingLibraryItem: Identifiable {
    case record(ReadingRecord), essay(ReadingEssay)
    var id:ReadingLibraryID { switch self { case .record(let r): .record(r.id); case .essay(let e): .essay(e.id) } }
    var title:String { switch self { case .record(let r): r.displayTitle; case .essay(let e): e.title } }
    var kind:String { switch self { case .record(let r): r.kind.rawValue; case .essay: "札记" } }
    var tags:[String] { switch self { case .record(let r): r.tags; case .essay(let e): e.tags } }
    var created:Date { switch self { case .record(let r): r.created; case .essay(let e): e.created } }
    var key:String { switch self { case .record(let r): "r:"+r.id.uuidString; case .essay(let e): "e:"+e.id.uuidString } }
    static func results(_ state:ReadingJournalState,query:String = "",kind:String = "全部",tag:String = "",removed:Bool = false) -> [Self] {
        let records = state.records.filter { !Task.isCancelled && $0.hasContent && ($0.removed != nil) == removed && (kind == "全部" || $0.kind.rawValue == kind) && $0.matches(query,tag:tag) }.map(Self.record)
        let essays = state.essays.filter { !Task.isCancelled && $0.hasContent && ($0.removed != nil) == removed && (kind == "全部" || kind == "札记") && (tag.isEmpty || $0.tags.contains(tag)) && $0.matches(query) }.map(Self.essay)
        return (records+essays).sorted { $0.created == $1.created ? $0.key < $1.key : $0.created > $1.created }
    }
}
extension ReadingJournal {
    func setRemoved(_ ids:Set<ReadingLibraryID>,removed:Bool) {
        guard !unreadable, !ids.isEmpty else { return }
        let date:Date? = removed ? Date() : nil
        change { state in
            for i in state.records.indices where ids.contains(.record(state.records[i].id)) { state.records[i].removed = date }
            for i in state.essays.indices where ids.contains(.essay(state.essays[i].id)) { state.essays[i].removed = date; if removed && state.currentEssay == state.essays[i].id { state.currentEssay = nil } }
        }
    }
}
