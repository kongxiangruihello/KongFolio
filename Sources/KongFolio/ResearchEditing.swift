import Foundation

struct PrintedPageRow: Identifiable, Equatable {
    var id = UUID()
    var start = 1
    var end = 1
    var first = 1
    var prefix = ""
    var style = PrintedPageSegment.Style.decimal
    init(_ segment: PrintedPageSegment) { id = segment.id; start = segment.start+1; end = segment.end+1; first = segment.first; prefix = segment.prefix; style = segment.style }
    var segment: PrintedPageSegment { PrintedPageSegment(id:id,start:start-1,end:end-1,first:first,prefix:prefix,style:style) }
    var preview: String { [segment.label(start-1) ?? "无页码",segment.label(end-1) ?? "无页码"].joined(separator:" → ") }
}
struct PeriodicalBatchRow: Identifiable {
    var id: String { path }
    var path: String
    var title: String
    var selected = false
    var record = PeriodicalRecord()
}
enum CorrectionConflicts {
    static func messages(_ rules: [ReplacementRule]) -> [String] {
        let grouped = Dictionary(grouping:rules,by:\.from)
        var messages = grouped.keys.sorted().compactMap { key -> String? in
            Set(grouped[key]!.map(\.to)).count > 1 ? "“" + key + "”有多个替换结果，请保留一个" : nil
        }
        for rule in rules where rules.contains(where: { $0.from != rule.from && rule.to.contains($0.from) }) { messages.append("“" + rule.from + "”的结果含其他规则的原字；本次不会串联替换") }
        return Array(Set(messages)).sorted()
    }
}
struct ResearchTopic: Codable, Identifiable {
    struct Item: Codable, Identifiable {
        var id = UUID()
        var annotation: ResearchAnnotation
        var reflection = ""
    }
    var id = UUID()
    var name: String
    var introduction = ""
    var items: [Item] = []
    mutating func add(_ annotations: [ResearchAnnotation]) {
        for value in annotations where !items.contains(where: { $0.annotation.key == value.key }) { items.append(Item(annotation:value)) }
    }
    mutating func move(_ id: UUID, delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index+delta) else { return }
        items.swapAt(index,index+delta)
    }
    func markdown(template: CitationTemplate, metadata: (String,Int) -> (String,String,String,String)) throws -> String {
        var result = "# " + name + "\n\n" + introduction + "\n\n"
        for item in items {
            let note = item.annotation, fields = metadata(note.path,note.page)
            let link = try ReadingShortcut(path:note.path,title:fields.1,mode:.fixed,position:ViewPosition(selection:note.page)).link().absoluteString
            let citation = template.render(author:fields.0,title:fields.1,periodical:fields.2,page:fields.3,quote:note.quote,link:link)
            result += "## " + fields.1 + " · " + fields.3 + "\n\n" + citation + "\n\n" + note.comment + "\n\n" + item.reflection + "\n\n[返回原文](" + link + ")\n\n"
        }
        return result
    }
}
