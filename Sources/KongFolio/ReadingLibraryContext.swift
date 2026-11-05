import Foundation

/// Only native context-menu targets are resolved; the unrelated current selection is never a fallback.
struct ReadingLibraryContext {
    var items:[ReadingLibraryItem]
    var removed:Bool
    var ids:Set<ReadingLibraryID> { Set(items.map(\.id)) }
    var single:ReadingLibraryItem? { items.count == 1 ? items.first : nil }
    var records:[ReadingRecord] { items.compactMap { if case .record(let record) = $0 { return record };return nil } }
    var canAppend:Bool { !removed && !items.isEmpty && records.count == items.count }
    static func resolve(_ targets:Set<ReadingLibraryID>,state:ReadingJournalState,removed:Bool) -> Self {
        let records = state.records.filter{targets.contains(.record($0.id)) && ($0.removed != nil) == removed && $0.hasContent}.map(ReadingLibraryItem.record)
        let essays = state.essays.filter{targets.contains(.essay($0.id)) && ($0.removed != nil) == removed && $0.hasContent}.map(ReadingLibraryItem.essay)
        return Self(items:(records+essays).sorted{$0.created == $1.created ? $0.key<$1.key : $0.created>$1.created},removed:removed)
    }
    func sources(limit:Int = 10) -> [ReadingCitation] {
        guard limit>0 else { return [] }
        var result:[ReadingCitation] = []
        for item in items { for citation in item.citations053 where !citation.source.path.isEmpty && !result.contains(where:{$0.source==citation.source}) { if result.count>=limit { return result };result.append(citation) } }
        return result
    }
    func clipboardText() -> String {
        func record(_ r:ReadingRecord) -> String {
            var parts:[String] = []
            if !r.quote.isEmpty { parts.append("原文：\n"+r.quote) }
            if r.imageAsset != nil { parts.append("[图片摘录：导出文件可保留图片]") }
            if !r.note.isEmpty { parts.append("我的笔记：\n"+r.note) }
            for citation in r.citations {
                parts.append(ReadingExportOrdering.citation(citation))
                if !citation.source.path.isEmpty,let link = SourceLink.url(citation.source) { parts.append("返回原文："+link.absoluteString) }
            }
            return parts.joined(separator:"\n\n")
        }
        return items.map { item in
            var parts = [item.kind+" · "+item.title]
            switch item {
            case .record(let r):parts.append(record(r))
            case .essay(let e):for block in e.blocks { if let r = block.record { parts.append(record(r)) };if !block.text.isEmpty { parts.append(block.text) } }
            }
            return parts.filter{!$0.isEmpty}.joined(separator:"\n\n")
        }.joined(separator:"\n\n——\n\n")
    }
}
enum ReadingLibraryContextAction { case edit,copy,export,organize,references,remove,append,source(SourceRef),newExcerpt,newNote,newEssay }
struct ReadingLibraryContextRequest:Identifiable {
    enum Kind { case organize,references,remove }
    let id = UUID()
    let kind:Kind
    let ids:Set<ReadingLibraryID>
    let removed:Bool
}
