import SwiftUI

/// Display-only emphasis, using the same original UTF-16 ranges as PDF search.
enum SearchResultHighlight {
    static func ranges(_ text:String,query:String)->[NSRange] {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,query.utf16.count<=500 else { return [] }
        var cache:[String:String]=[:]
        return ReadingServices.matches(in:text,query:query,cache:&cache,limit:200)
    }
    static func text(_ text:String,query:String)->AttributedString {
        var result=AttributedString(text)
        for match in ranges(text,query:query) {
            guard let range=Range(match,in:text),
                  let start=AttributedString.Index(range.lowerBound,within:result),
                  let end=AttributedString.Index(range.upperBound,within:result) else { continue }
            result[start..<end].backgroundColor = .yellow
            result[start..<end].foregroundColor = .black
        }
        return result
    }
}
