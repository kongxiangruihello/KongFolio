import AppKit
import PDFKit

extension Workspace {
    /// Marks a highlight in the document as the colouring of an excerpt card.
    static let cardKey = PDFAnnotationKey(rawValue: "KongFolioCard")

    /// Whether the source text of an excerpt is coloured in the document (a setting; on by default).
    static var tintsSources: Bool {
        get { UserDefaults.standard.object(forKey: LayoutKeys.tintSources) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: LayoutKeys.tintSources) }
    }

    /// True when this tab shows the file at `path` (a project, or the file the document was opened from).
    func matches(path: String) -> Bool {
        guard let url = projectURL ?? sourceURL else { return false }
        return url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private var sourcePath: String { (projectURL ?? sourceURL)?.path ?? "" }

    func sourceReference(page: PDFPage, rects: [CGRect], anchor: String? = nil) -> SourceRef {
        let index = document.index(for: page)
        return SourceRef(path: sourcePath, fileName: displayName, page: max(0, index), pageLabel: ReadingServices.pageLabel(page, index: index), rects: rects, anchor: anchor)
    }

    // MARK: Excerpting

    /// Sends the selected text to the workspace as a card that remembers its page and position.
    func excerptSelection() {
        guard let selected = pdfView?.currentSelection else { error = "请先在 PDF 中选中文字。扫描页需先 OCR。"; return }
        excerpt(selection: selected)
    }

    func excerpt(selection selected: PDFSelection) {
        guard let board = store?.board else { error = "工作区不可用。"; return }
        guard let raw = selected.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请先在 PDF 中选中文字。扫描页需先 OCR。"
            return
        }
        var first: PDFPage?
        var lines: [(page: PDFPage, selection: PDFSelection, rect: CGRect)] = []
        for line in selected.selectionsByLine() {
            for page in line.pages {
                if first == nil { first = page }
                if page === first { lines.append((page, line, line.bounds(for: page))) }
            }
        }
        guard let page = first ?? selected.pages.first else { error = "无法确定所选文字所在的页面。"; return }
        let anchorLine = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let source = sourceReference(page: page, rects: lines.map(\.rect), anchor: String(anchorLine.prefix(30)))
        let text = ExcerptText.tidy(raw)
        if let existing = board.existingExcerpt(text: text, source: source) {
            board.focus(existing.id)
            showBoardPane()
            status = "这段文字已经在工作区里"
            return
        }
        let id = board.addExcerpt(text: text, source: source)
        if Workspace.tintsSources { tint(cardID: id, color: board.card(id)?.color ?? .yellow, pages: lines.map { ($0.page, $0.rect) }, quote: text) }
        board.focus(id)
        showBoardPane()
        status = "已摘录到工作区"
    }

    /// Sends a captured region of the page (a figure, a table, a scanned passage) to the workspace.
    func excerptRegion(imageData: Data, size: CGSize, page: PDFPage, pageRect: CGRect) {
        guard let board = store?.board else { error = "工作区不可用。"; return }
        let id = board.addImage(imageData, size: size, source: sourceReference(page: page, rects: [pageRect]))
        if Workspace.tintsSources { tint(cardID: id, color: board.card(id)?.color ?? .blue, pages: [(page, pageRect)], quote: "") }
        board.focus(id)
        showBoardPane()
        status = "已把所选区域摘录到工作区"
    }

    /// Makes sure the workspace pane is visible after an excerpt.
    func showBoardPane() {
        UserDefaults.standard.set(true, forKey: LayoutKeys.board)
    }

    // MARK: Colouring the source

    /// Colours the excerpted text in the document. These are ordinary highlights (they can be undone, are saved with the
    /// project and appear in exported PDFs), marked with the card they belong to.
    private func tint(cardID: UUID, color: CardColor, pages: [(PDFPage, CGRect)], quote: String) {
        var added: [PDFAnnotation] = []
        for (page, rect) in pages {
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = color.nsColor.withAlphaComponent(0.4)
            annotation.setValue(cardID.uuidString, forAnnotationKey: Workspace.cardKey)
            if !quote.isEmpty { annotation.setValue(quote, forAnnotationKey: ReadingServices.quoteKey) }
            page.addAnnotation(annotation)
            added.append(annotation)
        }
        recordAnnotationsAdded(added)
    }

    private func tintedAnnotations(cardID: UUID) -> [PDFAnnotation] {
        var found: [PDFAnnotation] = []
        for index in 0..<count {
            guard let page = document.page(at: index) else { continue }
            found += page.annotations.filter { ($0.value(forAnnotationKey: Workspace.cardKey) as? String) == cardID.uuidString }
        }
        return found
    }

    /// Takes the colour off the document when its card is deleted (undoable).
    func removeTint(cardID: UUID) {
        let found = tintedAnnotations(cardID: cardID)
        guard !found.isEmpty else { return }
        let edits = beginAnnotationEdit(found)
        found.forEach { $0.page?.removeAnnotation($0) }
        commitAnnotationEdit(edits)
    }

    func recolorTint(cardID: UUID, color: CardColor) {
        let found = tintedAnnotations(cardID: cardID)
        guard !found.isEmpty else { return }
        let edits = beginAnnotationEdit(found)
        found.forEach { $0.color = color.nsColor.withAlphaComponent(0.4) }
        commitAnnotationEdit(edits)
    }

    /// The card a highlight belongs to, if it colours an excerpt.
    func cardID(of annotation: PDFAnnotation) -> UUID? {
        (annotation.value(forAnnotationKey: Workspace.cardKey) as? String).flatMap(UUID.init(uuidString:))
    }

    /// Clicking an excerpt's colour in the document shows its card in the workspace.
    func focusCard(_ id: UUID) {
        guard let board = store?.board, board.card(id) != nil else { return }
        showBoardPane()
        board.focus(id)
    }

    // MARK: Going to a place in the document

    /// Where an excerpt really is now: on the recorded page if its first words are still there, otherwise the nearest
    /// match elsewhere (pages may have been added, removed or reordered since the excerpt was made).
    func locate(anchor: String, near index: Int) -> (page: Int, rect: CGRect)? {
        if document.page(at: index)?.string?.contains(anchor) == true { return nil }
        let candidates = document.findString(anchor, withOptions: [.literal]).compactMap { match -> (Int, CGRect)? in
            guard let page = match.pages.first else { return nil }
            let position = document.index(for: page)
            return position == NSNotFound ? nil : (position, match.bounds(for: page))
        }
        return candidates.min { abs($0.0 - index) < abs($1.0 - index) }.map { (page: $0.0, rect: $0.1) }
    }

    /// Scrolls to a place in the document and marks it for a moment.
    func go(to position: ViewPosition, highlighting rects: [CGRect] = [], anchor: String? = nil) {
        guard count > 0 else { pendingView = position; return }
        var target = position
        var marks = rects
        if let anchor, !anchor.isEmpty, let found = locate(anchor: anchor, near: min(position.selection, count - 1)) {
            target = ViewPosition(selection: found.page, x: Double(found.rect.minX), y: Double(found.rect.maxY + 36), scale: nil)
            marks = [found.rect]
        }
        selection = max(0, min(target.selection, count - 1))
        selectedPages = [selection]
        readingPoint = target.point
        navigationToken = UUID()
        flash(marks, on: selection)
    }

    /// For a tab that is still loading: shows the source once the document is on screen.
    func revealWhenReady(_ source: SourceRef) {
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                if let self, self.pdfView?.document === self.document, self.count > 0 {
                    self.go(to: source.position, highlighting: source.rects, anchor: source.anchor)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.go(to: source.position, highlighting: source.rects, anchor: source.anchor)
        }
    }

    private func flash(_ rects: [CGRect], on index: Int) {
        guard !rects.isEmpty, let page = document.page(at: index) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let view = self?.pdfView, view.document === self?.document else { return }
            let marks = rects.compactMap { page.selection(for: $0) }
            marks.forEach { $0.color = NSColor.systemOrange.withAlphaComponent(0.55) }
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
            if workspace.count == 0 { workspace.pendingView = position; workspace.pendingReveal = source }
            select(workspace.id)
            if workspace.count > 0 { workspace.go(to: position, highlighting: source.rects, anchor: source.anchor) }
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
        target.pendingReveal = source
        select(target.id)
        target.load([url])
        return true
    }

    /// Wires the workspace to the documents: deleting or recolouring a card follows in the document's highlight.
    func connectBoardToDocuments() {
        board.onRemove = { [weak self] card in self?.workspaceShowing(card)?.removeTint(cardID: card.id) }
        board.onColorChange = { [weak self] card in self?.workspaceShowing(card)?.recolorTint(cardID: card.id, color: card.color) }
    }

    private func workspaceShowing(_ card: BoardCard) -> Workspace? {
        guard let source = card.source, card.kind != .note else { return nil }
        return tabs.compactMap(\.workspace).first { $0.count > 0 && $0.matches(path: source.path) }
    }
}
