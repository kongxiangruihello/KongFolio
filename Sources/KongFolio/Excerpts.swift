import AppKit
import PDFKit

extension Workspace {
    /// True when this tab shows the file at `path` (a project, or the file the document was opened from).
    func matches(path: String) -> Bool {
        guard let url = projectURL ?? sourceURL else { return false }
        return url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private var sourcePath: String { (projectURL ?? sourceURL)?.path ?? "" }

    func sourceReference(page: PDFPage, rects: [CGRect]) -> SourceRef {
        let index = document.index(for: page)
        return SourceRef(path: sourcePath, fileName: displayName, page: max(0, index), pageLabel: ReadingServices.pageLabel(page, index: index), rects: rects)
    }

    /// Sends the selected text to the workspace as a card that remembers its page and position.
    func excerptSelection() {
        guard let board = store?.board else { error = "工作区不可用。"; return }
        guard let selected = pdfView?.currentSelection, let raw = selected.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请先在 PDF 中选中文字。扫描页需先 OCR。"
            return
        }
        var first: PDFPage?
        var rects: [CGRect] = []
        for line in selected.selectionsByLine() {
            for page in line.pages {
                if first == nil { first = page }
                if page === first { rects.append(line.bounds(for: page)) }
            }
        }
        guard let page = first ?? selected.pages.first else { error = "无法确定所选文字所在的页面。"; return }
        board.addExcerpt(text: ExcerptText.tidy(raw), source: sourceReference(page: page, rects: rects))
        showBoardPane()
        status = "已摘录到工作区"
    }

    /// Sends a captured region of the page (a figure, a table, a scanned passage) to the workspace.
    func excerptRegion(imageData: Data, size: CGSize, page: PDFPage, pageRect: CGRect) {
        guard let board = store?.board else { error = "工作区不可用。"; return }
        board.addImage(imageData, size: size, source: sourceReference(page: page, rects: [pageRect]))
        showBoardPane()
        status = "已把所选区域摘录到工作区"
    }

    /// Makes sure the workspace pane is visible after the first excerpt.
    func showBoardPane() {
        UserDefaults.standard.set(true, forKey: LayoutKeys.board)
    }

    /// Scrolls to a place in the document and marks it for a moment.
    func go(to position: ViewPosition, highlighting rects: [CGRect] = []) {
        guard count > 0 else { pendingView = position; return }
        selection = max(0, min(position.selection, count - 1))
        selectedPages = [selection]
        readingPoint = position.point
        navigationToken = UUID()
        flash(rects, on: selection)
    }

    private func flash(_ rects: [CGRect], on index: Int) {
        guard !rects.isEmpty, let page = document.page(at: index) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let view = self?.pdfView, view.document === self?.document else { return }
            let marks = rects.compactMap { page.selection(for: $0) }
            marks.forEach { $0.color = NSColor.systemOrange.withAlphaComponent(0.5) }
            view.highlightedSelections = marks
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { view.highlightedSelections = nil }
        }
    }
}

extension WorkspaceStore {
    /// Takes the reader to a card's source: the tab that already shows the file, or a new tab that opens it.
    /// Returns false when the file cannot be found.
    @discardableResult func reveal(_ source: SourceRef) -> Bool {
        guard !source.path.isEmpty else {
            present(FolioError(message: "这张卡片的来源文档没有保存为文件，无法跳转。"))
            return false
        }
        let position = source.position
        if let workspace = tabs.compactMap(\.workspace).first(where: { $0.matches(path: source.path) }) {
            if workspace.count == 0 { workspace.pendingView = position }
            select(workspace.id)
            if workspace.count > 0 { workspace.go(to: position, highlighting: source.rects) }
            return true
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            present(FolioError(message: "找不到原文件：\(source.path)"))
            return false
        }
        let target: Workspace
        if let current = activeWorkspace, current.count == 0, !current.busy, current.sourceURL == nil, current.projectURL == nil { target = current } else { target = addWorkspace() }
        let url = URL(fileURLWithPath: source.path)
        if url.pathExtension.lowercased() == "kongfolio" { target.projectURL = url } else { target.sourceURL = url }
        target.pendingView = position
        select(target.id)
        target.load([url])
        return true
    }
}
