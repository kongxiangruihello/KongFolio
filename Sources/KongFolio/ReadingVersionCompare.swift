import Foundation

enum ReadingVersionCompare {
    struct Line:Identifiable { var id:Int;var old:String;var new:String;var changed:Bool { old != new } }
    static func lines(old:String,new:String) -> [Line] {
        let a = old.components(separatedBy:"\n"),b = new.components(separatedBy:"\n")
        return (0..<min(2000,max(a.count,b.count))).map { Line(id:$0,old:$0<a.count ? a[$0] : "",new:$0<b.count ? b[$0] : "") }
    }
    static func ownText(_ id:ReadingLibraryID,state:ReadingJournalState) -> String {
        switch id { case .record(let id):return state.records.first{$0.id == id}?.note ?? "";case .essay(let id):return state.essays.first{$0.id == id}?.blocks.map(\.text).joined(separator:"\n\n") ?? "" }
    }
    static func paragraphs(_ id:ReadingLibraryID,state:ReadingJournalState) -> [String] {
        switch id { case .record(let id): return (state.records.first{$0.id == id}?.note ?? "").components(separatedBy:"\n\n");case .essay(let id):return state.essays.first{$0.id == id}?.blocks.map(\.text) ?? [] }
    }
}