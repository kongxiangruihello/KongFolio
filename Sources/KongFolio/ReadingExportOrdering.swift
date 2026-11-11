import Foundation

enum ReadingExportItem:Identifiable {
    case record(ReadingRecord),essay(ReadingEssay)
    var id:String { switch self { case .record(let r):return "r:"+r.id.uuidString;case .essay(let e):return "e:"+e.id.uuidString } }
    var title:String { switch self { case .record(let r):return r.displayTitle;case .essay(let e):return e.title } }
    var created:Date { switch self { case .record(let r):return r.created;case .essay(let e):return e.created } }
    var citations: [ReadingCitation] {
        switch self {
        case .record(let record): return record.citations053
        case .essay(let essay): return ReadingLibraryItem.essay(essay).citations053
        }
    }
    var records:[ReadingRecord] { switch self { case .record(let r):return [r];case .essay(let e):return e.blocks.compactMap(\.record) } }
    var snapshot:ReadingExportSnapshot { switch self { case .record(let r):return ReadingExportSnapshot(title:r.displayTitle,records:[r]);case .essay(let e):return ReadingExportSnapshot(title:e.title,essay:e) } }
}
extension ReadingExportSnapshot {
    var orderedItems:[ReadingExportItem] {
        let values = records.map(ReadingExportItem.record)+([essay].compactMap{$0}+(essays ?? [])).map(ReadingExportItem.essay)
        guard let order else { return values }
        let indices = Dictionary(order.enumerated().map{($0.element,$0.offset)},uniquingKeysWith:min)
        return values.enumerated().sorted{(indices[$0.element.id] ?? Int.max,$0.offset)<(indices[$1.element.id] ?? Int.max,$1.offset)}.map(\.element)
    }
}
enum ReadingExportOrdering {
    enum Sort:String,CaseIterable,Codable { case manual = "手动顺序",date = "记录日期",book = "书名",page = "来源页码" }
    static func sorted(_ items:[ReadingExportItem],by sort:Sort) -> [ReadingExportItem] {
        items.enumerated().sorted { a,b in
            switch sort {
            case .manual:return a.offset<b.offset
            case .date:return a.element.created == b.element.created ? a.offset<b.offset : a.element.created<b.element.created
            case .book,.page:
                let x = a.element.citations.first,y = b.element.citations.first
                if (x == nil) != (y == nil) { return x != nil }
                if x?.title != y?.title { return (x?.title ?? "")<(y?.title ?? "") }
                if sort == .page,x?.source.page != y?.source.page { return (x?.source.page ?? 0)<(y?.source.page ?? 0) }
                return a.offset<b.offset
            }
        }.map(\.element)
    }
    static func citation(_ value:ReadingCitation) -> String {
        let edition = value.edition.flatMap{$0.isEmpty ? nil : $0}
        let publication=value.publication?.summary ?? ""
        return (value.author.isEmpty ? "" : value.author+"：")+"《"+value.title+"》"+(edition.map{"，"+$0} ?? "")+(publication.isEmpty ? "":"，"+publication)+"，PDF 第 \(value.source.page+1) 页"+(value.source.pageLabel.map{"（印刷页码 "+$0+"）"} ?? "")
    }
    static func sourceLine(_ citation: ReadingCitation, index: Int, rendered: String) -> String {
        "\(index+1). "+sourceDetail(citation,rendered:rendered)
    }
    static func sourceDetail(_ citation: ReadingCitation, rendered: String) -> String {
        let original = citation.tracking?.capturedPage
        let moved = original.map { $0 != citation.source.page } ?? false
        let priorPage = moved ? "（记录时为第 \(original.map { $0+1 } ?? 0) 页）" : ""
        let review = citation.source.invalidPage053 == true || citation.tracking?.needsReview == true ? " · 出处待核对" : ""
        let file = citation.source.fileName.isEmpty ? "" : " · 原文件："+citation.source.fileName
        return rendered+priorPage+file+review
    }
    static func citationKey(_ value:ReadingCitation) -> String { "s"+String(OCRPageCache.digest(Data((citation(value)+"\n"+value.source.path).utf8)).prefix(20)) }
    static func footnotes(_ snapshot:ReadingExportSnapshot) -> [String:String] {
        guard snapshot.options?.includeSources != false,snapshot.options?.footnotes == true else { return [:] }
        var formatter=ReadingCitationFormat053(),result:[String:String]=[:]
        for c in snapshot.citations053 { let key=citationKey(c);if result[key]==nil { result[key]=sourceDetail(c,rendered:formatter.render(c,shorten:snapshot.options?.shortenedCitations053==true)) } }
        return result
    }
    static func warnings(_ snapshot:ReadingExportSnapshot) -> [String] {
        var result:[String] = []
        if snapshot.allRecords.contains(where:{$0.citations.isEmpty}) { result.append("部分记录没有出处，请核对后再用于引用。") }
        if snapshot.allRecords.contains(where:{$0.quote.contains("�") || $0.quote.contains("[待核]")}) { result.append("摘录中含有待核文字。") }
        return result
    }
}
extension ReadingRecordExport {
    static func word(_ snapshot:ReadingExportSnapshot,assets:URL,to file:URL,warnings:[String]=[]) throws {
        var document=try rich(snapshot,assets:assets,wordFootnotes:true)
        for warning in warnings { document.blocks.append(.paragraph(RichTextDocument.styled("附图提示："+warning,options:document.options,markdown:false),heading:0)) }
        try RichTextWord.write(document,to:file,readingFootnotes:ReadingExportOrdering.footnotes(snapshot))
    }
}
