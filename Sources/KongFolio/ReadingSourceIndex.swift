import Foundation

struct ReadingSourceIndex {
    struct Entry {
        let number: Int
        let citation: ReadingCitation
        var label: String { "出处 \(number)" }
        var detail: String {
            let original = ReadingExportOrdering.citation(citation)
            return ReadingExportOrdering.sourceDetail(citation,rendered:original)
        }
    }
    let entries: [Entry]
    private let numbers: [String:Int]

    init(_ snapshot:ReadingExportSnapshot) {
        guard snapshot.options?.includeSources != false, snapshot.options?.includeSourceIndex == true else {
            entries = []; numbers = [:]; return
        }
        var known: [String:Int] = [:]
        var rows: [Entry] = []
        for citation in snapshot.citations053 {
            let key = ReadingExportOrdering.citationKey(citation)
            guard known[key] == nil else { continue }
            let number = rows.count+1
            known[key] = number
            rows.append(Entry(number:number,citation:citation))
        }
        entries = rows
        numbers = known
    }

    func label(_ citation:ReadingCitation) -> String? {
        guard !numbers.isEmpty else { return nil }
        return numbers[ReadingExportOrdering.citationKey(citation)].map{"出处 \($0)"}
    }

    static func link(_ citation:ReadingCitation,options:ReadingExportOptions) -> String? {
        guard citation.source.invalidPage053 != true else { return nil }
        if let relative = options.sourceLinks?[citation.source.path] {
            return relative+"#page="+String(citation.source.page+1)
        }
        return SourceLink.url(citation.source)?.absoluteString
    }
}
