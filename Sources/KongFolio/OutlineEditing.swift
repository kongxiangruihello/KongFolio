import Foundation
import PDFKit

/// Writing a table of contents for a book that has none (typical of scans). The entries are saved in the project
/// and written into the PDF's own outline whenever the file is exported or saved as a PDF.
extension Workspace {
    static let maximumOutlineDepth = 5

    /// Adds the current page to the table of contents, after the entries that point to earlier pages (and to this one).
    func addOutlineEntry(title: String, depth: Int) {
        guard count > 0 else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "第 \(selection + 1) 页" : trimmed
        checkpoint()
        let position = outlineEntries.lastIndex { $0.page <= selection }.map { $0 + 1 } ?? 0
        let before = position > 0 ? outlineEntries[position - 1].depth : -1
        outlineEntries.insert(OutlineEntry(page: selection, label: label, depth: min(max(depth, 0), before + 1, Self.maximumOutlineDepth)), at: position)
        outlineChanged()
        status = "已加入目录：\(label)"
    }

    func renameOutlineEntry(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = outlineEntries.firstIndex(where: { $0.id == id }), outlineEntries[index].label != trimmed else { return }
        checkpoint()
        outlineEntries[index].label = trimmed
        outlineChanged()
    }

    func deleteOutlineEntry(_ id: UUID) {
        guard outlineEntries.contains(where: { $0.id == id }) else { return }
        checkpoint()
        outlineEntries.removeAll { $0.id == id }
        outlineChanged()
    }

    /// Moves an entry one level in (+1) or out (-1). An entry can be at most one level deeper than the one above it.
    func indentOutlineEntry(_ id: UUID, by change: Int) {
        guard let index = outlineEntries.firstIndex(where: { $0.id == id }) else { return }
        let limit = min(index > 0 ? outlineEntries[index - 1].depth + 1 : 0, Self.maximumOutlineDepth)
        let depth = min(max(outlineEntries[index].depth + change, 0), limit)
        guard depth != outlineEntries[index].depth else { return }
        checkpoint()
        outlineEntries[index].depth = depth
        outlineChanged()
    }

    func clearOutline() {
        guard !outlineEntries.isEmpty, confirm("清除整个目录？", "已有的 \(outlineEntries.count) 条目录会被删除，可以撤销。", action: "清除") else { return }
        checkpoint()
        outlineEntries = []
        outlineChanged()
    }

    /// Puts `entries` in place of the whole table of contents.
    func replaceOutline(_ entries: [OutlineEntry]) {
        checkpoint()
        outlineEntries = entries
        outlineChanged()
    }

    private func outlineChanged() {
        ReadingServices.applyOutline(outlineEntries, to: document)
        cachedPDF = nil
        edited(pdfChanged: false)
    }
}
