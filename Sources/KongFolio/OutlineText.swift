import Foundation

/// The table of contents as plain text, one entry per line: indentation (a tab or two spaces) is the level, the page
/// number comes last. "页码偏移" turns the printed numbers into physical pages: physical page = printed number + offset.
///
///     序 3
///     卷之一 5
///       第一章 …… 7
enum OutlineText {
    struct Result: Equatable {
        var entries: [OutlineEntry]
        var problems: [String]
    }

    static func serialize(_ entries: [OutlineEntry], offset: Int) -> String {
        entries.map { String(repeating: "  ", count: max(0, $0.depth)) + $0.label + "\t" + String($0.page + 1 - offset) }.joined(separator: "\n")
    }

    private static func asciiDigits(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            (0xFF10...0xFF19).contains(scalar.value) ? Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!) : Character(scalar)
        })
    }

    static func parse(_ text: String, offset: Int, pageCount: Int, maximumDepth: Int = 5) -> Result {
        var entries: [OutlineEntry] = []
        var problems: [String] = []
        let pattern = try? NSRegularExpression(pattern: #"^(.*?)[\s.…·．。\-—_　]*([0-9]+)$"#)
        for (offset0, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let number = offset0 + 1
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var tabs = 0, spaces = 0
            for character in raw {
                if character == "\t" { tabs += 1 } else if character == " " || character == "　" { spaces += 1 } else { break }
            }
            let body = asciiDigits(raw.trimmingCharacters(in: .whitespaces))
            guard let match = pattern?.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)), match.numberOfRanges == 3 else {
                problems.append("第 \(number) 行没有页码：\(raw.trimmingCharacters(in: .whitespaces))")
                continue
            }
            let label = (body as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { problems.append("第 \(number) 行没有标题"); continue }
            guard let printed = Int((body as NSString).substring(with: match.range(at: 2))) else { problems.append("第 \(number) 行的页码太大"); continue }
            let page = printed + offset - 1
            guard (0..<pageCount).contains(page) else {
                problems.append("第 \(number) 行的页码 \(printed) 超出范围（对应第 \(page + 1) 页，全书 \(pageCount) 页）：\(label)")
                continue
            }
            let wanted = tabs + spaces / 2
            let depth = min(max(wanted, 0), (entries.last?.depth ?? -1) + 1, maximumDepth)
            entries.append(OutlineEntry(page: page, label: label, depth: depth))
        }
        return Result(entries: entries, problems: problems)
    }
}

extension Workspace {
    /// Replaces the whole table of contents with the entries in `text`. Lines that cannot be read are reported and skipped.
    func applyOutlineText(_ text: String, offset: Int) {
        guard count > 0 else { return }
        let result = OutlineText.parse(text, offset: offset, pageCount: count)
        if result.entries.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "没有读到有效的目录行。\n" + result.problems.prefix(4).joined(separator: "\n")
            return
        }
        replaceOutline(result.entries)
        status = "目录已更新：\(result.entries.count) 条" + (result.problems.isEmpty ? "" : "，跳过 \(result.problems.count) 行（\(result.problems[0])）")
    }
}
