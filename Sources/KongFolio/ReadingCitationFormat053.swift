import Foundation

struct ReadingCitationFormat053 {
    var seen=Set<String>()
    static func bookKey(_ c:ReadingCitation)->String { [c.author,c.title,c.edition ?? "",c.publication?.summary ?? ""].joined(separator:"|") }
    mutating func render(_ citation:ReadingCitation,shorten:Bool)->String {
        let repeatBook = !seen.insert(Self.bookKey(citation)).inserted
        if shorten && repeatBook { return (citation.author.isEmpty ? "":citation.author+"，")+"《"+citation.title+"》，PDF 第 \(citation.source.page+1) 页" }
        return ReadingExportOrdering.citation(citation)
    }
}
struct ReadingWordComment053:Codable { var text:String;var author:String;var date:Date? }
