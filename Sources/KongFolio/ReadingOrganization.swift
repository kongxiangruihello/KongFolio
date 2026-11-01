import Foundation

struct ReadingReference: Identifiable {
    var id:String
    var title:String
    var kind:String
    var removed:Bool
    var text:String
}
extension ReadingJournal {
    static func normalizedTags(_ text:String) -> [String] { var seen = Set<String>(); return text.replacingOccurrences(of:"，",with:",").split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty && seen.insert($0).inserted} }
    func organize(_ ids:Set<ReadingLibraryID>,tags:String,topic:String,remove:Bool = false) {
        guard !unreadable, !ids.isEmpty else { return }
        var additions = Self.normalizedTags(tags); let name = topic.trimmingCharacters(in:.whitespacesAndNewlines)
        if !name.isEmpty { additions.append("专题："+name) }; var seen = Set<String>(); additions = additions.filter{seen.insert($0).inserted}; guard !additions.isEmpty else { return }
        func changed(_ old:[String]) -> [String] { remove ? old.filter{!additions.contains($0)} : old+additions.filter{!old.contains($0)} }
        change { state in
            for i in state.records.indices where state.records[i].removed == nil && ids.contains(.record(state.records[i].id)) { state.records[i].tags = changed(state.records[i].tags); state.records[i].modified = Date() }
            for i in state.essays.indices where state.essays[i].removed == nil && ids.contains(.essay(state.essays[i].id)) { state.essays[i].tags = changed(state.essays[i].tags); state.essays[i].modified = Date() }
        }
    }
    var topics:[String] { Array(Set((state.records.flatMap(\.tags)+state.essays.flatMap(\.tags)).filter{$0.hasPrefix("专题：")}.map{String($0.dropFirst(3))})).sorted() }
    func references(to id:ReadingLibraryID) -> (outgoing:[ReadingReference],incoming:[ReadingReference]) {
        var outgoing:[ReadingReference] = [], incoming:[ReadingReference] = []
        func reference(_ record:ReadingRecord) -> ReadingReference { ReadingReference(id:"record:"+record.id.uuidString,title:record.displayTitle,kind:record.kind.rawValue,removed:record.removed != nil,text:[record.quote,record.note,record.citations.map(\.display).joined(separator:"\n")].filter{!$0.isEmpty}.joined(separator:"\n\n")) }
        switch id {
        case .record(let uuid):
            if let current = record(uuid) { outgoing = current.linkedRecords.compactMap { source in state.records.first{$0.id == source}.map(reference) } }
            for r in state.records where r.id != uuid && r.linkedRecords.contains(uuid) { incoming.append(reference(r)) }
            for e in state.essays where e.blocks.contains(where:{$0.record?.id == uuid || $0.record?.linkedRecords.contains(uuid) == true}) {
                incoming.append(ReadingReference(id:"essay:"+e.id.uuidString,title:e.title,kind:"札记",removed:e.removed != nil,text:e.blocks.map{$0.text}.joined(separator:"\n\n")))
            }
        case .essay(let uuid):
            var known = Set<UUID>()
            for block in essay(uuid)?.blocks ?? [] { if let frozen = block.record, known.insert(frozen.id).inserted { var r = reference(frozen); r.removed = state.records.first{$0.id == frozen.id}.map{$0.removed != nil} ?? true; outgoing.append(r) } }
        }
        return (outgoing,incoming)
    }
}
