import Foundation

struct ReadingSearchRequest:Hashable {
    var revision:Int
    var query = ""
    var kind = "全部"
    var tag = ""
    var topic = ""
    var removed = false
}
actor ReadingSearchWorker {
    static let shared = ReadingSearchWorker()
    func library(_ state:ReadingJournalState,request:ReadingSearchRequest) -> [ReadingLibraryItem] {
        guard !Task.isCancelled else { return [] };return ReadingLibraryItem.results(state,query:request.query,kind:request.kind,tag:request.tag,removed:request.removed).filter{request.topic.isEmpty || $0.tags.contains("专题："+request.topic)}
    }
    func records(_ state:ReadingJournalState,query:String,notes:Bool,book:String?,tag:String,removed:Bool,recent:Bool) -> [ReadingDeskHit] {
        guard !Task.isCancelled else { return [] };return state.records.filter { !Task.isCancelled && $0.hasContent && ($0.removed != nil) == removed && (notes ? $0.kind == .note : $0.kind != .note) && $0.matches(query,book:book,tag:tag,after:recent ? Date().addingTimeInterval(-7*86400) : nil) }.sorted { $0.created == $1.created ? $0.id.uuidString<$1.id.uuidString : $0.created>$1.created }.map(ReadingDeskHit.record)
    }
    func essays(_ state:ReadingJournalState,query:String) -> [ReadingEssay] { state.essays.filter{!Task.isCancelled && $0.hasContent && $0.removed == nil && $0.matches(query)}.sorted{$0.created == $1.created ? $0.id.uuidString<$1.id.uuidString : $0.created>$1.created} }
}

enum ReadingDeskHit:Identifiable {
    case record(ReadingRecord),essay(ReadingEssay)
    var id:String { switch self { case .record(let value): return "record:"+value.id.uuidString; case .essay(let value): return "essay:"+value.id.uuidString } }
    var date:Date { switch self { case .record(let value): return value.created; case .essay(let value): return value.created } }
}
