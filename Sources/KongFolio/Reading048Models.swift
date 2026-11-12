import Foundation
import AppKit

enum ReaderToolbarContext {
    case empty, pdf, text

    func supports(_ action: FileToolbarAction) -> Bool {
        switch action {
        case .search,.annotate,.pdfPages: return self == .pdf
        case .tools,.signature: return self != .text
        case .save,.export: return self != .empty
        default: return true
        }
    }
}

struct ReaderToolbarProfile:Codable,Equatable {
    static let key = "KongFolio.readerToolbar048"
    static let defaultActions:[FileToolbarAction] = FileToolbarAction.allCases
    var order:[String] = Self.defaultActions.map(\.rawValue)
    private static let defaultPins: [FileToolbarAction] = [.newFile,.open,.search,.annotate,.sidebar,.export]
    var pinned:Set<String> = Set(Self.defaultPins.map(\.rawValue))
    var actions:[FileToolbarAction] {
        var seen = Set<FileToolbarAction>()
        var previous=Set<String>()
        var upgraded=order.compactMap{FileToolbarAction(rawValue:$0)?.unified.rawValue}.filter{previous.insert($0).inserted}
        if !upgraded.contains("search") { upgraded.insert("search",at:upgraded.firstIndex(of:"open").map{$0+1} ?? min(upgraded.count,2)) }
        if !upgraded.contains("pdfPages") { upgraded.insert("pdfPages",at:upgraded.firstIndex(of:"search").map{$0+1} ?? min(upgraded.count,3)) }
        if !upgraded.contains("signature"),let i=upgraded.firstIndex(where:{FileToolbarAction(rawValue:$0)?.unified == .tools}) { upgraded.insert("signature",at:i+1) }
        return (upgraded+Self.defaultActions.map(\.rawValue)).compactMap { raw in
            guard let action = FileToolbarAction(rawValue:raw)?.unified,seen.insert(action).inserted else { return nil };return action
        }
    }
    private var unifiedPins:Set<FileToolbarAction> { Set(pinned.compactMap{FileToolbarAction(rawValue:$0)?.unified}) }
    func visible(width:Double, context:ReaderToolbarContext = .pdf)->[FileToolbarAction] {
        let pins = unifiedPins
        let available = actions.filter { pins.contains($0) && context.supports($0) }
        let capacity = SingleRowToolbarPolicy.visibleCount(width:width)
        guard available.count > capacity else { return available }
        let primary: Set<FileToolbarAction> = [.search,.annotate,.sidebar]
        let priority = available.filter { primary.contains($0) }
        let secondary = available.filter { !primary.contains($0) }
        let retained = Set((priority+secondary).prefix(capacity))
        return available.filter { retained.contains($0) }
    }
    func hidden(width:Double, context:ReaderToolbarContext = .pdf)->[FileToolbarAction] {
        let selected = Set(visible(width:width,context:context))
        return actions.filter { !selected.contains($0) }
    }
    static func decode(_ data:Data?)->Self { guard let data,var p = try? JSONDecoder().decode(Self.self,from:data) else { return Self() };p.order = p.actions.map(\.rawValue);p.pinned = Set(p.pinned.compactMap{FileToolbarAction(rawValue:$0)?.unified.rawValue});return p }
    static func load(_ defaults:UserDefaults = .standard)->Self { decode(defaults.data(forKey:key)) }
    func save(_ defaults:UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data,forKey:Self.key) } }
    mutating func move(_ action:FileToolbarAction,by delta:Int) { order = actions.map(\.rawValue);guard let i = order.firstIndex(of:action.rawValue),order.indices.contains(i+delta) else { return };order.swapAt(i,i+delta) }
}
struct ReadingCitationUpdate:Identifiable {
    var id:UUID { block };var essay:UUID;var block:UUID;var previous:ReadingRecord;var current:ReadingRecord
}
struct ReadingBulkCheckpoint { var before:ReadingJournalState;var after:ReadingJournalState;var label:String }
extension ReadingJournal {
    func citationUpdates(_ essay:UUID)->[ReadingCitationUpdate] {
        guard let e = self.essay(essay) else { return [] }
        return e.blocks.compactMap { block in
            guard let previous = block.record,let current = state.records.first(where:{$0.id == previous.id && $0.removed == nil}),ReadingCitationUpdate.changed(previous,current) else { return nil }
            return ReadingCitationUpdate(essay:essay,block:block.id,previous:previous,current:current)
        }
    }
    func synchronizeCitation(_ update:ReadingCitationUpdate) throws {
        guard !unreadable,let current = state.records.first(where:{$0.id == update.current.id}),current == update.current,let block = essay(update.essay)?.blocks.first(where:{$0.id == update.block}),block.record == update.previous else { throw FolioError(message:"引用又有变化，请重新比较") }
        let before = state
        editEssay(update.essay) { e in if let i = e.blocks.firstIndex(where:{$0.id == update.block}) { e.blocks[i].record = current } }
        bulkCheckpoint = ReadingBulkCheckpoint(before:before,after:state,label:"更新笔记引用")
    }
    func finishBulk(_ before:ReadingJournalState,_ label:String) { if state != before { bulkCheckpoint = ReadingBulkCheckpoint(before:before,after:state,label:label) } }
    var canUndoBulk:Bool { !unreadable && bulkCheckpoint?.after == state }
    func undoBulk() throws {
        guard let checkpoint = bulkCheckpoint,canUndoBulk else { throw FolioError(message:"操作后已有其他修改，请从备份中核对恢复，避免覆盖新内容") }
        try state.validate();change { $0 = checkpoint.before };bulkCheckpoint = nil
    }
}
extension ReadingCitationUpdate {
    static func changed(_ a:ReadingRecord,_ b:ReadingRecord)->Bool { a.quote != b.quote || a.note != b.note || a.citations != b.citations || a.imageAsset != b.imageAsset || a.title != b.title }
}
struct ReadingTextHit:Identifiable {
    enum Field: String {
        case original = "摘录原文", corrected = "校订文字", note = "我的笔记", comment = "PDF 原评论", remark = "摘录备注"
    }
    var id:String { identity+":"+String(range.location) }
    var identity:String
    var range:NSRange
    var context:String
    var source:String
    var field: Field = .note
    var matchedText: String { (source as NSString).substring(with:range) }
}
enum ReadingTextSearch {
    static func hits(_ text:String,query:String,identity:String,field:ReadingTextHit.Field = .note,exact:Bool = false,limit:Int = 200)->[ReadingTextHit] {
        guard !query.isEmpty,query.utf16.count <= 500 else { return [] }
        let ns = text as NSString
        var cache: [String:String] = [:]
        let ranges: [NSRange]
        if exact {
            var matches: [NSRange] = []
            var location = 0
            while matches.count < limit && location < ns.length {
                let range = ns.range(of:query,options:.literal,range:NSRange(location:location,length:ns.length-location))
                guard range.location != NSNotFound else { break }
                matches.append(range)
                location = NSMaxRange(range)
            }
            ranges = matches
        } else { ranges = ReadingServices.matches(in:text,query:query,cache:&cache,limit:limit) }
        return ranges.map { range in
            let start = max(0,range.location-24), end = min(ns.length,NSMaxRange(range)+50)
            let visible = ns.rangeOfComposedCharacterSequences(for:NSRange(location:start,length:end-start))
            let context = ns.substring(with:visible).replacingOccurrences(of:"\n",with:" ↵ ")
            return ReadingTextHit(identity:identity,range:range,context:context,source:text,field:field)
        }
    }

    static func fields(_ item:ReadingLibraryItem,query:String,scope:ReadingLibraryOptions053.Scope = .all,exact:Bool = false,limit:Int = 200)->[ReadingTextHit] {
        let terms = ReadingSearchExpression053(String(query.prefix(500))).groups.flatMap{$0}.filter{!$0.negative}.map(\.text)
        guard !terms.isEmpty else { return [] }
        var seen = Set<String>()
        var remaining = max(0,limit)
        func field(_ text:String,_ identity:String,_ kind:ReadingTextHit.Field)->[ReadingTextHit] {
            guard remaining > 0,!text.isEmpty else { return [] }
            switch scope {
            case .all: break
            case .mine: guard kind == .note || kind == .remark else { return [] }
            case .quote: guard kind == .original || kind == .corrected else { return [] }
            case .comment: guard kind == .comment else { return [] }
            }
            var result: [ReadingTextHit] = []
            for term in terms where remaining > 0 {
                let matches = hits(text,query:term,identity:identity,field:kind,exact:exact,limit:remaining)
                for match in matches where remaining > 0 && seen.insert(match.id).inserted {
                    result.append(match)
                    remaining -= 1
                }
            }
            return result
        }
        func sourceFields(_ record: ReadingRecord, key: String, inEssay: Bool)->[ReadingTextHit] {
            let prefix = inEssay ? "essay-" : ""
            let original = record.originalOCR ?? record.originalQuote
            if !inEssay, record.excerptSegments != nil {
                return record.textExcerptSegments.flatMap { part in
                    let id = key+":"+part.id.uuidString
                    let now = field(part.text,"segment:"+id,part.originalText == nil ? .original : .corrected)
                    let before = part.originalText.flatMap { $0 != part.text ? $0 : nil }
                        .map { field($0,"segment-original:"+id,.original) } ?? []
                    return now+before
                }
            }
            let current = field(record.quote,prefix+"quote:"+key,original == nil ? .original : .corrected)
            let before = original.flatMap { $0 != record.quote ? $0 : nil }.map { field($0,prefix+"original:"+key,.original) } ?? []
            let comments = field(record.pdfOrigin?.contents ?? "",prefix+"comment:"+key,.comment)
            return current+before+comments
        }
        let direct: [ReadingTextHit]
        switch item {
        case .record(let record):
            let key = record.id.uuidString
            direct = sourceFields(record,key:key,inEssay:false)+field(record.note,"note:"+key,.note)
                + field(record.excerptRemark ?? "","remark:"+key,.remark)
        case .essay(let essay):
            direct = essay.blocks.flatMap { block -> [ReadingTextHit] in
                let key = essay.id.uuidString+":"+block.id.uuidString
                let source = block.record.map { sourceFields($0,key:key,inEssay:true) } ?? []
                return field(block.text,"essay:"+key,.note)+source
            }
        }
        return direct+(item.extras053.quotations ?? []).flatMap {
            field($0.text,"quotation:"+item.id.uuid053.uuidString+":"+$0.id.uuidString,.original)
        }
    }
}
