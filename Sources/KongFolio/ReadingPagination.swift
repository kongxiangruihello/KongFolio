import Foundation

/// One bounded page shared by record lists, essays and the excerpt chooser.
struct ReadingPagination: Equatable {
    let total: Int
    let size: Int
    let index: Int
    var last: Int { max(0, (total - 1) / size) }
    var range: Range<Int> { let start = index * size; return start..<min(total, start + size) }
    var label: String { "第 \(index + 1) / \(last + 1) 页" }
    var countLabel: String { total == 0 ? "共 0 条" : "共 \(total) 条 · 本页 \(range.lowerBound + 1)–\(range.upperBound)" }
    init(total: Int, page: Int, size: Int) {
        self.total = max(0, total); self.size = [10, 20, 50].contains(size) ? size : 10
        self.index = min(max(0, page), max(0, (self.total - 1) / self.size))
    }
}
