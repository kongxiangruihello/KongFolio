import Foundation

/// Matching for the quick tab switcher: every word typed must be found in the name, either as a run of characters
/// (best when it starts the name or a word) or as characters in order with gaps.
enum TabSearch {
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// How well `token` matches `name`; nil when it does not match at all.
    static func score(_ name: String, token: String) -> Int? {
        let n = fold(name), t = fold(token)
        guard !t.isEmpty else { return 0 }
        if let range = n.range(of: t) {
            let position = n.distance(from: n.startIndex, to: range.lowerBound)
            var value = 1000 - position * 5
            if position == 0 {
                value += 200
            } else if let previous = n[..<range.lowerBound].last, !previous.isLetter && !previous.isNumber {
                value += 100
            }
            return value
        }
        var index = n.startIndex
        var gaps = 0
        var last: String.Index?
        for character in t {
            guard let found = n[index...].firstIndex(of: character) else { return nil }
            if let last, n.index(after: last) != found { gaps += 1 }
            last = found
            index = n.index(after: found)
        }
        return max(1, 300 - gaps * 20)
    }

    /// The indices of `names` that match `query`, best first (ties keep their order). An empty query matches everything.
    static func rank(_ names: [String], query: String) -> [Int] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return Array(names.indices) }
        var scored: [(index: Int, value: Int)] = []
        for (index, name) in names.enumerated() {
            var total = 0
            var matched = true
            for token in tokens {
                guard let value = score(name, token: token) else { matched = false; break }
                total += value
            }
            if matched { scored.append((index, total)) }
        }
        return scored.sorted { $0.value != $1.value ? $0.value > $1.value : $0.index < $1.index }.map(\.index)
    }
}
