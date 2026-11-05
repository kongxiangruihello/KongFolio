import Foundation

struct ReadingSearchRequest:Hashable {
    var revision:Int
    var query = ""
    var kind = "全部"
    var tag = ""
    var topic = ""
    var removed = false
    var recent = false
    var untagged = false
    var bookPath:String? = nil
    var options053:ReadingLibraryOptions053? = nil
    var indexFolder:String? = nil
}
actor ReadingSearchWorker {
    static let shared = ReadingSearchWorker()
    func library(_ state:ReadingJournalState,request:ReadingSearchRequest) async -> [ReadingLibraryItem] {
        if let options=request.options053 { return await library053(state,request:request,options:options) }
        guard !Task.isCancelled else { return [] };let recentIDs = Set(state.records.filter{$0.modified >= Date().addingTimeInterval(-7*86400)}.map{ReadingLibraryID.record($0.id)}+state.essays.filter{$0.modified >= Date().addingTimeInterval(-7*86400)}.map{ReadingLibraryID.essay($0.id)})
        return ReadingLibraryItem.results(state,query:request.query,kind:request.kind,tag:request.tag,removed:request.removed).filter{ (request.bookPath == nil || $0.isFromBook(request.bookPath!)) && (request.topic.isEmpty || $0.tags.contains("专题："+request.topic)) && (!request.recent || recentIDs.contains($0.id)) && (!request.untagged || $0.tags.isEmpty) }
    }
    func records(_ state:ReadingJournalState,query:String,notes:Bool,book:String?,tag:String,removed:Bool,recent:Bool) -> [ReadingDeskHit] {
        guard !Task.isCancelled else { return [] };let records = state.records.filter { !Task.isCancelled && $0.hasContent && ($0.removed != nil) == removed && (notes ? $0.kind == .note : [.excerpt,.image].contains($0.kind)) && $0.matches(query,book:book,tag:tag,after:recent ? Date().addingTimeInterval(-7*86400) : nil) }.sorted { $0.created == $1.created ? $0.id.uuidString<$1.id.uuidString : $0.created>$1.created }.map(ReadingDeskHit.record)
        guard notes else { return records }
        let essays = state.essays.filter { $0.hasContent && ($0.removed != nil) == removed && (!recent || $0.modified >= Date().addingTimeInterval(-7*86400)) && $0.matches(query) && (tag.isEmpty || $0.tags.contains(tag)) && (book == nil || ReadingLibraryItem.essay($0).isFromBook(book!)) }.map(ReadingDeskHit.essay)
        return (records+essays).sorted{$0.date>$1.date}
    }
    func essays(_ state:ReadingJournalState,query:String) -> [ReadingEssay] { state.essays.filter{!Task.isCancelled && $0.hasContent && $0.removed == nil && $0.matches(query)}.sorted{$0.created == $1.created ? $0.id.uuidString<$1.id.uuidString : $0.created>$1.created} }
}

enum ReadingDeskHit:Identifiable {
    case record(ReadingRecord),essay(ReadingEssay)
    var id:String { switch self { case .record(let value): return "record:"+value.id.uuidString; case .essay(let value): return "essay:"+value.id.uuidString } }
    var date:Date { switch self { case .record(let value): return value.created; case .essay(let value): return value.created } }
}

extension ReadingSearchWorker {
    func library053(_ state:ReadingJournalState,request:ReadingSearchRequest,options:ReadingLibraryOptions053) async->[ReadingLibraryItem] {
        let expression=ReadingSearchExpression053(request.query)
        let all=ReadingLibraryItem.results(state,kind:request.kind,tag:request.tag,removed:request.removed)
        let candidates:Set<String>?
        if let folder=request.indexFolder { candidates=await ReadingSearchIndex053.shared.candidates(ReadingLibraryItem.results(state,kind:"全部",removed:false)+ReadingLibraryItem.results(state,kind:"全部",removed:true),revision:request.revision,folder:URL(fileURLWithPath:folder),query:expression,exact:options.exact) } else { candidates=nil }
        let result=all.filter { item in
            !Task.isCancelled && (candidates == nil || candidates!.contains(item.key)) && item.filtered053(options) && expression.matches(item.searchText053(options.scope),exact:options.exact) && (request.bookPath == nil || item.isFromBook(request.bookPath!)) && (request.topic.isEmpty || item.tags.contains("专题："+request.topic)) && (!request.untagged || item.tags.isEmpty) && (!request.recent || item.modified053 >= Date().addingTimeInterval(-7*86400))
        }
        return result.sorted { a,b in
            if options.groupChapters,a.chapter053 != b.chapter053 { return a.chapter053.localizedStandardCompare(b.chapter053) == .orderedAscending }
            switch options.sort {
            case .created:return a.created==b.created ? a.key<b.key:a.created>b.created
            case .modified:return a.modified053==b.modified053 ? a.key<b.key:a.modified053>b.modified053
            case .title:return a.title==b.title ? a.key<b.key:a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .source:let x=a.citations053.first,y=b.citations053.first;if x?.title != y?.title { return (x?.title ?? "").localizedStandardCompare(y?.title ?? "") == .orderedAscending };return (x?.source.page ?? -1)==(y?.source.page ?? -1) ? a.key<b.key:(x?.source.page ?? -1)<(y?.source.page ?? -1)
            case .relevance:let term=ReadingSearchExpression053.normalized(expression.firstPositive),x=ReadingSearchExpression053.normalized(a.title).contains(term),y=ReadingSearchExpression053.normalized(b.title).contains(term);return x==y ? a.created>b.created:x
            }
        }
    }
}
