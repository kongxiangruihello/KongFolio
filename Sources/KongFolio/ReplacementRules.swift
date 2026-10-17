import Foundation

/// Corrections applied to the text of an export, for mistakes the recognition makes again and again (戊/戌/戍, 己/已/巳).
/// They change the exported text only; the recognition record and the PDF are untouched.
struct ReplacementRule: Equatable, Codable {
    var from: String
    var to: String
}

enum ReplacementRules {
    static let textKey = "KongFolio.replacementRules"
    static let enabledKey = "KongFolio.replacementRulesOn"

    /// One rule per line: `错=正`, `错→正` or `错->正`. Lines starting with # are comments; an empty right side deletes.
    static func parse(_ text: String) -> [ReplacementRule] {
        var rules: [ReplacementRule] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var parts: [String]?
            for separator in ["->", "→", "＝", "="] {
                if let range = line.range(of: separator) {
                    parts = [String(line[..<range.lowerBound]), String(line[range.upperBound...])]
                    break
                }
            }
            guard let parts else { continue }
            let from = parts[0].trimmingCharacters(in: .whitespaces), to = parts[1].trimmingCharacters(in: .whitespaces)
            if !from.isEmpty { rules.append(ReplacementRule(from: from, to: to)) }
        }
        return rules
    }

    /// The rules in order, each over the whole text.
    static func apply(_ rules: [ReplacementRule], to text: String) -> String {
        rules.reduce(text) { $0.replacingOccurrences(of: $1.from, with: $1.to) }
    }
}
