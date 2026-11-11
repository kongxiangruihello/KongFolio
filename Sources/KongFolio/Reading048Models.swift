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
    var id:String { identity+":"+String(range.location) };var identity:String;var range:NSRange;var context:String;var source:String
}
enum ReadingTextSearch {
    static func hits(_ text:String,query:String,identity:String)->[ReadingTextHit] {
        guard !query.isEmpty,query.utf16.count <= 500 else { return [] };let ns = text as NSString;var p = 0,result:[ReadingTextHit] = []
        while p < ns.length,result.count < 200 {
            let r = ns.range(of:query,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],range:NSRange(location:p,length:ns.length-p));guard r.location != NSNotFound,r.length > 0 else { break }
            let a = max(0,r.location-18),b = min(ns.length,NSMaxRange(r)+35)
            result.append(ReadingTextHit(identity:identity,range:r,context:ns.substring(with:NSRange(location:a,length:b-a)).replacingOccurrences(of:"\n",with:" ↵ "),source:text));p = NSMaxRange(r)
        };return result
    }
    static func fields(_ item:ReadingLibraryItem,query:String)->[ReadingTextHit] {
        switch item {
        case .record(let r):return hits(r.quote,query:query,identity:"quote:"+r.id.uuidString)+hits(r.note,query:query,identity:"note:"+r.id.uuidString)
        case .essay(let e):return e.blocks.flatMap{hits($0.text,query:query,identity:"essay:"+e.id.uuidString+":"+$0.id.uuidString)}
        }
    }
}
