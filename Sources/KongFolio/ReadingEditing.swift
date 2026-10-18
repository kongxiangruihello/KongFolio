import AppKit
import PDFKit

/// Where a link added to the selected text should lead.
enum LinkTarget: Equatable {
    case page(Int)   // 0-based
    case web(URL)

    /// "12" → page 12 (if the document has that many pages); "example.com" or "https://…" → a web address.
    static func parse(_ text: String, pageCount: Int) -> LinkTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = Int(trimmed) { return (1...max(1, pageCount)).contains(number) ? .page(number - 1) : nil }
        let candidate = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let host = url.host ?? (url.scheme == "mailto" ? "mail" : nil), host.contains(".") || host == "mail" else { return nil }
        return .web(url)
    }
}

/// Things done to the page list and the view rather than to the marks.
enum PageEditing {
    /// A page number after `page` was inserted at `insertedAt` (everything from there on moves down one).
    static func shifted(_ page: Int, insertedAt: Int) -> Int { page >= insertedAt ? page + 1 : page }

    /// Where the pasted copy of a mark goes: a little down and to the right, kept inside the page.
    static func pasteBounds(_ bounds: CGRect, offset: CGFloat = 14, in page: CGRect) -> CGRect {
        var moved = bounds.offsetBy(dx: offset, dy: -offset)
        if moved.maxX > page.maxX { moved.origin.x = page.maxX - moved.width }
        if moved.minX < page.minX { moved.origin.x = page.minX }
        if moved.minY < page.minY { moved.origin.y = page.minY }
        if moved.maxY > page.maxY { moved.origin.y = page.maxY - moved.height }
        return moved
    }

    /// The next (step 1) or previous (step -1) index in a ring of `count` items, from `current` (nil = none yet).
    static func ring(_ current: Int?, step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step >= 0 ? 0 : count - 1 }
        return ((current + step) % count + count) % count
    }
}

extension Workspace {
    // MARK: Night reading

    static let nightKey = "KongFolio.nightReading"

    func applyNightReading() {
        guard let view = pdfView else { return }
        view.wantsLayer = true
        view.contentFilters = nightReading ? (CIFilter(name: "CIColorInvert").map { [$0] } ?? []) : []
    }

    // MARK: Search stepping

    /// ⌘G / ⇧⌘G: the next or previous match of the search in the sidebar, wrapping round.
    func stepSearch(_ step: Int) {
        guard !searchResults.isEmpty else {
            if !search.isEmpty { startSearch() }
            return
        }
        guard let next = PageEditing.ring(searchCursor, step: step, count: searchResults.count) else { return }
        searchCursor = next
        let hit = searchResults[next]
        goToSearch(hit)
        status = "第 \(next + 1) / \(searchResults.count) 处"
    }

    // MARK: Pages

    /// A blank page the size of the current one, after it (or before it when `before`).
    func insertBlankPage(before: Bool = false) {
        guard count > 0, let reference = page else { return }
        let index = before ? selection : selection + 1
        checkpoint()
        let blank = PDFPage()
        let box = reference.bounds(for: .mediaBox)
        blank.setBounds(CGRect(origin: .zero, size: box.size), for: .mediaBox)
        blank.setBounds(CGRect(origin: .zero, size: box.size), for: .cropBox)
        alignMeta()
        document.insert(blank, at: index)
        pageMeta.insert(PageMeta(), at: min(index, pageMeta.count))
        bookmarks = bookmarks.map { var b = $0; b.page = PageEditing.shifted(b.page, insertedAt: index); return b }
        outlineEntries = outlineEntries.map { var e = $0; e.page = PageEditing.shifted(e.page, insertedAt: index); return e }
        ReadingServices.applyOutline(outlineEntries, to: document)
        selection = index
        selectedPages = [index]
        navigationToken = UUID()
        changed()
        status = "已插入空白页，现在共 \(count) 页"
    }

    // MARK: Marks

    func copySelectedAnnotations() {
        var marks = annotations(ofNotes: selectedNoteIDs)
        if marks.isEmpty, let one = selectedAnnotation { marks = [one] }
        copiedAnnotations = marks.compactMap { $0.copy() as? PDFAnnotation }
        status = copiedAnnotations.isEmpty ? "先选中要复制的标注（编辑标注点选，或在列表里勾选）" : "已复制 \(copiedAnnotations.count) 个标注"
    }

    /// Puts the copied marks on the page being read, a little off from where they were, one undo for all.
    func pasteAnnotations() {
        guard let target = page, !copiedAnnotations.isEmpty else { status = "没有复制过标注"; return }
        let frame = target.bounds(for: .cropBox)
        var added: [PDFAnnotation] = []
        for original in copiedAnnotations {
            guard let copy = original.copy() as? PDFAnnotation else { continue }
            copy.bounds = PageEditing.pasteBounds(original.bounds, in: frame)
            target.addAnnotation(copy)
            added.append(copy)
        }
        recordAnnotationsAdded(added)
        copiedAnnotations = added.compactMap { $0.copy() as? PDFAnnotation }
        status = "已粘贴 \(added.count) 个标注（可撤销）"
    }

    func duplicateSelectedAnnotations() {
        copySelectedAnnotations()
        pasteAnnotations()
    }

    // MARK: Links

    /// Makes each line of the selected text a link to a page or an address.
    func addLinkToSelection(_ text: String) {
        guard let chosen = pdfView?.currentSelection, !(chosen.string ?? "").isEmpty else { status = "先选中要加链接的文字"; return }
        guard let target = LinkTarget.parse(text, pageCount: count) else { error = "请输入页码（1–\(count)）或网址。"; return }
        var added: [PDFAnnotation] = []
        for line in chosen.selectionsByLine() {
            for linePage in line.pages {
                let bounds = line.bounds(for: linePage)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
                switch target {
                case .page(let number):
                    guard let destinationPage = document.page(at: number) else { continue }
                    let box = destinationPage.bounds(for: .cropBox)
                    link.destination = PDFDestination(page: destinationPage, at: CGPoint(x: box.minX, y: box.maxY))
                case .web(let url):
                    link.url = url
                }
                link.border = nil
                linePage.addAnnotation(link)
                added.append(link)
            }
        }
        guard !added.isEmpty else { return }
        recordAnnotationsAdded(added)
        status = "已加链接 \(added.count) 处（可撤销）"
    }

    /// Removes the links under the selected text.
    func removeLinksInSelection() {
        guard let chosen = pdfView?.currentSelection else { status = "先选中带链接的文字"; return }
        var targets: [PDFAnnotation] = []
        for line in chosen.selectionsByLine() {
            for linePage in line.pages {
                let bounds = line.bounds(for: linePage)
                targets += linePage.annotations.filter { $0.type == "Link" && $0.bounds.intersects(bounds) }
            }
        }
        guard !targets.isEmpty else { status = "选中的文字下没有链接"; return }
        let edits = beginAnnotationEdit(targets)
        for link in targets { link.page?.removeAnnotation(link) }
        commitAnnotationEdit(edits)
        status = "已去掉 \(targets.count) 处链接（可撤销）"
    }
}

/// A one-line question with a text field.
@MainActor enum TextPrompt {
    static func ask(_ title: String, detail: String, initial: String = "", button: String = "确定") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
