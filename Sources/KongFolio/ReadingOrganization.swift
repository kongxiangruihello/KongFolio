import Foundation

struct ReadingReference: Identifiable {
    var id:String
    var title:String
    var kind:String
    var removed:Bool
    var text:String
    var destination: ReadingLibraryID? = nil
    var target: ReadingDetailRequest.Target? = nil
    var additionalTargets: [ReadingDetailRequest.Target] = []
}
extension ReadingJournal {
    static func normalizedTags(_ text:String) -> [String] { var seen = Set<String>(); return text.replacingOccurrences(of:"，",with:",").split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty && seen.insert($0).inserted} }
    func organize(_ ids:Set<ReadingLibraryID>,tags:String,topic:String,remove:Bool = false) {
        let beforeBulk = state
        defer { finishBulk(beforeBulk,"批量整理") }
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
            for r in state.records where r.id != uuid && r.linkedRecords.contains(uuid) {
                var entry = reference(r)
                if r.kind == .note && !r.quote.isEmpty { entry.target = .linkedQuote }
                incoming.append(entry)
            }
            for e in state.essays {
                for block in e.blocks where block.record?.id == uuid || block.record?.linkedRecords.contains(uuid) == true {
                    let position = ReadingDetailRequest.Target.block(block.id)
                    incoming.append(ReadingReference(id:"block:"+block.id.uuidString,title:e.title,kind:"笔记",
                        removed:e.removed != nil,text:[block.record?.quote ?? "",block.text].filter{!$0.isEmpty}.joined(separator:"\n\n"),
                        destination:.essay(e.id),target:position))
                }
            }
        case .essay(let uuid):
            var known = Set<UUID>()
            for block in essay(uuid)?.blocks ?? [] { if let frozen = block.record, known.insert(frozen.id).inserted { var r = reference(frozen); r.removed = state.records.first{$0.id == frozen.id}.map{$0.removed != nil} ?? true; outgoing.append(r) } }
        }
        if let source = libraryItem053(id) {
            for quotation in source.extras053.quotations ?? [] {
                let target: ReadingLibraryID = quotation.targetKind == "essay" ? .essay(quotation.recordID) : .record(quotation.recordID)
                outgoing.append(ReadingReference(id:"quotation:"+quotation.id.uuidString,title:quotation.title,
                    kind:quotation.kind ?? "资料",removed:libraryItem053(target) == nil,text:quotation.text,destination:target))
            }
        }
        let entries = state.records.map(ReadingLibraryItem.record)+state.essays.map(ReadingLibraryItem.essay)
        for entry in entries where entry.id != id {
            let removed: Bool
            switch entry { case .record(let r): removed = r.removed != nil; case .essay(let e): removed = e.removed != nil }
            for quotation in entry.extras053.quotations ?? [] where quotation.recordID == id.uuid053 &&
                (quotation.targetKind == nil || id.isEssay053 == (quotation.targetKind == "essay")) {
                incoming.append(ReadingReference(id:"quotation:"+quotation.id.uuidString,title:entry.title,kind:entry.kind,
                    removed:removed,text:quotation.text,destination:entry.id,target:.quotation(quotation.id)))
            }
        }
        var grouped: [ReadingReference] = []
        var positions: [ReadingLibraryID:Int] = [:]
        for entry in incoming {
            guard let item = entry.item else { grouped.append(entry); continue }
            guard let index = positions[item] else {
                positions[item] = grouped.count
                grouped.append(entry)
                continue
            }
            guard let target = entry.target,grouped[index].target != target,
                  !grouped[index].additionalTargets.contains(target) else { continue }
            if grouped[index].target == nil { grouped[index].target = target }
            else { grouped[index].additionalTargets.append(target) }
        }
        return (outgoing,grouped)
    }
}
