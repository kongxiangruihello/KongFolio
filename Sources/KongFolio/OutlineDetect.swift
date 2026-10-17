import Foundation
import PDFKit

/// A heading found in the text of a page that could become a table-of-contents entry.
struct OutlineCandidate: Identifiable, Equatable {
    var id: String { "\(page)-\(title)" }
    var page: Int
    var title: String
    var depth: Int
}

/// Finds volume and chapter headings ("卷之一", "第二章", "序", "凡例"…) at the start of pages, for books that have no
/// table of contents. Only the first lines of each page are looked at: in a vertical book the first lines are the
/// rightmost columns, which is where a volume begins.
enum OutlineDetect {
    static let numerals = "〇零一二三四五六七八九十百千廿卅壹貳贰參叁肆伍陸陆柒捌玖拾兩两0-9０-９"
    static let alone: Set<String> = ["序", "自序", "原序", "小序", "敘", "叙", "引", "弁言", "凡例", "例言", "目錄", "目录", "總目", "总目", "跋", "後序", "后序", "後記", "后记", "附錄", "附录", "題記", "题记"]
    static let majorUnits = "篇編编部集卷冊册"

    private static func clean(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "　·．.。，、：:「」『』“”（）()")))
    }

    /// The heading a line is, or nil. Long lines are cut at 30 characters.
    static func heading(in raw: String) -> (title: String, depth: Int)? {
        let line = clean(raw)
        guard !line.isEmpty else { return nil }
        if alone.contains(line) { return (line, 0) }
        let volume = try? NSRegularExpression(pattern: "^卷(之)?[\(numerals)]+")
        let numbered = try? NSRegularExpression(pattern: "^第[\(numerals)]+([章節节篇回卷編编集部册冊])")
        let whole = NSRange(location: 0, length: (line as NSString).length)
        func cut(_ text: String) -> String { text.count > 30 ? String(text.prefix(30)) : text }
        if volume?.firstMatch(in: line, range: whole) != nil { return (cut(line), 0) }
        if let match = numbered?.firstMatch(in: line, range: whole), match.numberOfRanges == 2 {
            let unit = (line as NSString).substring(with: match.range(at: 1))
            return (cut(line), majorUnits.contains(unit) ? 0 : 1)
        }
        return nil
    }

    /// `pages`: for each page, its lines (or columns) from the start of the page.
    static func candidates(pages: [(page: Int, lines: [String])], linesPerPage: Int = 3) -> [OutlineCandidate] {
        var found: [OutlineCandidate] = []
        for entry in pages.sorted(by: { $0.page < $1.page }) {
            for line in entry.lines.filter({ !clean($0).isEmpty }).prefix(linesPerPage) {
                guard let heading = heading(in: line) else { continue }
                // The same heading again within a few pages is a running title, not a new section.
                if let last = found.last(where: { $0.title == heading.title }), entry.page - last.page <= 3 { break }
                found.append(OutlineCandidate(page: entry.page, title: heading.title, depth: heading.depth))
                break
            }
        }
        return found
    }

    /// `existing` plus `chosen`, in page order, without entries that are already there and with levels that never skip.
    static func merged(_ existing: [OutlineEntry], adding chosen: [OutlineCandidate]) -> [OutlineEntry] {
        var all = existing
        for candidate in chosen where !all.contains(where: { $0.page == candidate.page && $0.label == candidate.title }) {
            all.append(OutlineEntry(page: candidate.page, label: candidate.title, depth: candidate.depth))
        }
        let ordered = all.enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
        var result: [OutlineEntry] = []
        for var entry in ordered {
            entry.depth = min(max(entry.depth, 0), (result.last?.depth ?? -1) + 1, Workspace.maximumOutlineDepth)
            result.append(entry)
        }
        return result
    }
}

extension Workspace {
    /// The first lines of a page, in reading order: the right-most columns of a vertical page that has been recognised
    /// here, otherwise the lines of its text layer.
    func openingLines(of index: Int, limit: Int = 4) -> [String] {
        if let columns = OrderedText.verticalColumns(meta(index).ocrRegions ?? []) { return Array(columns.prefix(limit)) }
        let text = ReadingServices.repairIdeographs(document.page(at: index)?.string ?? "")
        return Array(text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(limit))
    }

    func findOutlineCandidates() {
        guard count > 0 else { return }
        let pages = (0..<count).map { (page: $0, lines: openingLines(of: $0)) }
        outlineCandidates = OutlineDetect.candidates(pages: pages)
        outlineCandidatesChosen = Set(outlineCandidates.map(\.id))
        outlineCandidatesHadText = pages.contains { !$0.lines.isEmpty }
        showOutlineCandidates = true
    }

    func addChosenOutlineCandidates() {
        let chosen = outlineCandidates.filter { outlineCandidatesChosen.contains($0.id) }
        guard !chosen.isEmpty else { return }
        replaceOutline(OutlineDetect.merged(outlineEntries, adding: chosen))
        status = "已把 \(chosen.count) 条标题加入目录"
    }
}
