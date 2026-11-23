import SwiftUI
import PDFKit

struct PDFCanvas: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        NativePDFCanvas(workspace: workspace)
            .overlay(alignment: .topLeading) {
                if let store = workspace.store {
                    PDFExcerptSelectionPrompt(store: store, workspace: workspace)
                        .padding(12)
                }
            }
    }
}

private struct NativePDFCanvas: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    func makeNSView(context: Context) -> ReadingPDFContainer {
        let view = DrawingPDFView(); view.workspace = workspace; view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.backgroundColor = .windowBackgroundColor
        workspace.pdfView = view
        let coordinator = context.coordinator
        coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.schedulePosition(view: view, workspace: view?.workspace) }
        }
        return ReadingPDFContainer(pdfView: view)
    }
    func updateNSView(_ container: ReadingPDFContainer, context: Context) {
        guard let view = container.pdfView else { return }
        if view.workspace !== workspace {
            if let previous = view.workspace, previous.pdfView === view { previous.pdfView = nil }
            context.coordinator.resetPosition()
            view.clearSourceHighlight()
            view.cancelExcerptSelections()
        }
        workspace.pdfView = view
        if workspace.tool != .select || workspace.showsPageThumbnails {
            view.cancelExcerptSelections()
            view.hideSelectionToolbar()
        }
        view.workspace = workspace
        let replaced = view.document !== workspace.document
        let display: PDFDisplayMode
        switch workspace.readingLayout {
        case .single: display = .singlePage
        case .twoUp: display = .twoUp
        case .continuous: display = .singlePageContinuous
        }
        let layoutChanged = view.displayMode != display
        if replaced {
            view.clearSourceHighlight()
            view.cancelExcerptSelections()
            view.dismissCommentEditor()
            view.document = workspace.document
            workspace.loadReadingRulerIfNeeded()
            context.coordinator.navigation = nil
        }
        // Keep PDFKit attached, but apply only the final page selection when the reader is visible.
        guard !workspace.showsPageThumbnails else { return }
        view.refreshReadingRuler()
        if layoutChanged { view.displayMode = display }
        if replaced || layoutChanged || context.coordinator.navigation != workspace.navigationToken {
            if let scale = workspace.readingScale { view.autoScales = false; view.scaleFactor = scale } else { view.autoScales = true }
            if let page = workspace.page {
                if let point = workspace.readingPoint { view.go(to: PDFDestination(page: page, at: point)) }
                else { view.go(to: page) }
            }
            context.coordinator.navigation = workspace.navigationToken
        }
        if view.contentFilters.isEmpty == workspace.nightReading { workspace.applyNightReading() }
        if context.coordinator.revision != workspace.revision { view.layoutDocumentView(); context.coordinator.revision = workspace.revision }
        context.coordinator.observeScroll(view: view)
        if replaced || layoutChanged { view.needsDisplay = true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ container: ReadingPDFContainer, coordinator: Coordinator) {
        coordinator.stop()
        guard let view = container.pdfView else { return }
        if let workspace = view.workspace, workspace.pdfView === view { workspace.pdfView = nil }
        view.releaseReadingResources()
        view.removeFromSuperview(); container.pdfView = nil
    }
    // Notification callbacks run on the main queue; all mutable access is on MainActor.
    final class Coordinator: @unchecked Sendable {
        var navigation: UUID?
        var scrollObserver: NSObjectProtocol?
        var revision: UUID?
        var observer: NSObjectProtocol?
        weak var clip: NSClipView?
        private weak var visitedPage: PDFPage?
        private var positionTask: Task<Void, Never>?
        @MainActor func schedulePosition(view: DrawingPDFView?, workspace: Workspace?) {
            guard positionTask == nil else { return }
            positionTask = Task { @MainActor [weak self, weak view, weak workspace] in
                // Coalesce PDFKit's page and scroll notifications into one update per turn.
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.positionTask = nil
                guard let view, let workspace,
                      !workspace.showsPageThumbnails,
                      workspace.pdfView === view, view.document === workspace.document,
                      let page = view.currentPage else { return }
                let index = workspace.document.index(for: page)
                guard index != NSNotFound else { return }
                if index != workspace.selection {
                    workspace.selection = index
                    if workspace.selectedPages.count <= 1 { workspace.selectedPages = [index] }
                    workspace.scheduleRecovery()
                }
                if self.visitedPage !== page { self.visitedPage = page; workspace.noteVisit(index) }
                workspace.captureReadingPosition(); view.refreshReadingRuler()
            }
        }
        @MainActor func observeScroll(view: DrawingPDFView) {
            let current = view.documentView?.enclosingScrollView?.contentView
            guard current !== clip else { return }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil; clip = current
            guard let current else { return }
            current.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: current, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    view?.refreshSourceHighlight()
                    self?.schedulePosition(view:view,workspace:view?.workspace)
                }
            }
        }
        func resetPosition() {
            positionTask?.cancel(); positionTask = nil; visitedPage = nil
            navigation = nil; revision = nil
        }
        func stop() {
            resetPosition()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            observer = nil; scrollObserver = nil; clip = nil; visitedPage = nil
        }
        deinit { stop() }
    }
}
/// SwiftUI can cache a representable's root NSView. Keep the expensive PDFKit child detachable.
final class ReadingPDFContainer: NSView {
    var pdfView: DrawingPDFView?
    init(pdfView: DrawingPDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        pdfView.frame = bounds; pdfView.autoresizingMask = [.width, .height]
        addSubview(pdfView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
final class DrawingPDFView: ManagedPDFView, SignaturePlacing, ReadingResourceReleasing, ReadingSourceHighlighting {
    weak var workspace: Workspace?
    private var points: [CGPoint] = []
    private weak var drawingPage: PDFPage?
    private var provisional: PDFAnnotation?
    private lazy var readingGuide = ReadingRulerOverlay(pdfView:self)
    func refreshReadingRuler() {
        if readingGuide.superview == nil { readingGuide.frame = bounds; readingGuide.autoresizingMask = [.width,.height]; addSubview(readingGuide) }
        readingGuide.isHidden = workspace?.readingRuler.enabled != true; readingGuide.needsDisplay = true
    }
    override func layout() { super.layout(); readingGuide.needsDisplay = true; refreshSourceHighlight() }
    private var sourceHighlight: ReadingSourceOverlay?
    private var sourceHighlightExpiry: Task<Void,Never>?

    func showSourceHighlight(_ rects:[CGRect],on page:PDFPage,keep:Bool) {
        clearSourceHighlight()
        let overlay = ReadingSourceOverlay(pdfView:self,page:page,rects:rects,color:keep ? .systemYellow : .systemOrange)
        sourceHighlight = overlay
        addSubview(overlay,positioned:.above,relativeTo:nil)
        if !keep {
            sourceHighlightExpiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds:2_500_000_000) } catch { return }
                self?.clearSourceHighlight()
            }
        }
    }

    func refreshSourceHighlight() {
        sourceHighlight?.needsDisplay = true
        excerptSelectionOverlays.forEach { $0.needsDisplay = true }
        if let anchor = excerptSelections.last, let selectionBar { positionSelectionToolbar(selectionBar, near: anchor) }
    }

    func clearSourceHighlight() {
        sourceHighlightExpiry?.cancel()
        sourceHighlightExpiry = nil
        sourceHighlight?.removeFromSuperview()
        sourceHighlight = nil
    }
    private lazy var strokePreview = StrokePreviewView(pdfView: self)
    private var moving: PDFAnnotation?
    private var pendingMove: [PendingAnnotationEdit] = []
    private var moveStart = CGPoint.zero
    private var originalOrigin = CGPoint.zero
    private var didMove = false
    /// The card of an excerpt colour that was pressed (a click without dragging shows the card in the workspace).
    private var pressedCard: UUID?
    private var pressMoved = false
    private var excerptDragStart: NSPoint?
    private var excerptDragSource: PDFExcerptDragSource?
    /// Rubber band of the region excerpt tool.
    private var regionStart: CGPoint?
    private weak var regionPage: PDFPage?
    private(set) var commentEditor: NSPopover?
    private var pressedComment: (page: PDFPage, annotation: PDFAnnotation)?
    private lazy var regionView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderWidth = 1.5
        view.layer?.borderColor = NSColor.systemBlue.cgColor
        view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        view.isHidden = true
        return view
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if regionView.superview == nil { addSubview(regionView) }
        if strokePreview.superview == nil {
            strokePreview.frame = bounds
            strokePreview.autoresizingMask = [.width, .height]
            addSubview(strokePreview)
        }
    }

    /// SwiftUI may cache the native view after a tab disappears. Drop its PDF and overlays explicitly.
    func releaseReadingResources() {
        endSignaturePlacement(); cancelExcerptSelections(); hideSelectionToolbar(); clearSourceHighlight(); dismissCommentEditor()
        points.removeAll(); drawingPage = nil; provisional = nil; moving = nil
        pendingMove.removeAll(); contextSignature = nil; regionStart = nil; regionPage = nil; pressedComment = nil
        excerptDragStart = nil; excerptDragSource = nil
        strokePreview.annotation = nil; strokePreview.page = nil
        strokePreview.removeFromSuperview(); regionView.removeFromSuperview(); readingGuide.removeFromSuperview()
        clearSelection(); highlightedSelections = nil; delegate = nil; document = nil; workspace = nil

    }

    // MARK: Signature placement
    private var placement: SignaturePlacementView?

    func beginSignaturePlacement(_ image: CGImage, widthFraction: Double, page: PDFPage?, rect: CGRect?) {
        endSignaturePlacement()
        let overlay = SignaturePlacementView(image: image)
        if let page, let rect {
            overlay.frame = convert(rect, from: page).intersection(bounds)
        } else {
            let width = max(40, bounds.width * widthFraction)
            overlay.frame = SignatureStamp.fit(aspect: overlay.aspect, width: width, center: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds)
        }
        addSubview(overlay)
        placement = overlay
        window?.makeFirstResponder(self)
    }

    func resizeSignaturePlacement(widthFraction: Double) {
        guard let overlay = placement else { return }
        let center = CGPoint(x: overlay.frame.midX, y: overlay.frame.midY)
        overlay.frame = SignatureStamp.fit(aspect: overlay.aspect, width: max(40, bounds.width * widthFraction), center: center, in: bounds)
    }

    func resizePageImage(widthInPoints: CGFloat) {
        guard let overlay = placement, let target = signaturePlacement() else { return }
        let pageBounds = convert(target.page.bounds(for:.cropBox),from:target.page)
        let crop = target.page.bounds(for:.cropBox)
        let quarterTurn = abs(target.page.rotation % 180) == 90
        let displayedWidth = quarterTurn ? crop.height : crop.width
        guard displayedWidth > 0 else { return }
        let width = widthInPoints * pageBounds.width / displayedWidth
        let center = CGPoint(x:overlay.frame.midX,y:overlay.frame.midY)
        overlay.frame = SignatureStamp.fit(aspect:overlay.aspect,width:width,center:center,in:pageBounds)
        workspace?.updatePageImageSize()
    }

    func signaturePlacement() -> (page: PDFPage, rect: CGRect)? {
        guard let overlay = placement,
              let page = page(for: CGPoint(x: overlay.frame.midX, y: overlay.frame.midY), nearest: true) else { return nil }
        return (page, convert(overlay.frame, to: page))
    }

    func endSignaturePlacement() {
        placement?.removeFromSuperview()
        placement = nil
    }

    /// ⌘C on a selection copies in reading order (columns right to left on a vertical page); with nothing selected it stays PDFKit's.
    override func copy(_ sender: Any?) {
        if let workspace, !(currentSelection?.string ?? "").isEmpty { workspace.copyInReadingOrder() } else { super.copy(sender) }
    }

    func resetExcerptRegion() {
        regionStart = nil
        regionPage = nil
        regionView.isHidden = true
        regionView.frame = .zero
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !excerptSelections.isEmpty {
            cancelExcerptSelections()
            workspace?.status = "已取消增加选区"
            return
        }
        if event.keyCode == 53, let workspace, workspace.tool == .region {
            workspace.endReadingRegionCapture()
            return
        }
        if event.keyCode == 53, let workspace, workspace.showsPDFExcerptTools || workspace.awaitsPDFExcerptText {
            if workspace.awaitsPDFExcerptText {
                workspace.endPDFExcerptSelection()
            } else {
                workspace.showsPDFExcerptTools = false
            }
            return
        }
        if event.keyCode == 53, drawingPage != nil, moving == nil {
            provisional = nil; points = []; drawingPage = nil
            workspace?.drawingInProgress = false
            strokePreview.annotation = nil; strokePreview.needsDisplay = true
            return
        }
        if placement != nil, let workspace {
            switch event.keyCode {
            case 36, 76: workspace.confirmSignaturePlacement(); return
            case 53: workspace.cancelSignaturePlacement(); return
            default: break
            }
        }
        if let workspace, !workspace.readingLocked, workspace.showAnnotationBar, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if event.keyCode == 53 { workspace.selectTool(.select); return }
            if [51, 117].contains(event.keyCode), workspace.selectedAnnotation != nil { workspace.deleteAnnotation(); return }
            if let key = event.charactersIgnoringModifiers, key.count == 1, let match = AnnotationShortcuts.tool(for: key) {
                workspace.selectTool(match.tool, highlighter: match.highlighter)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if workspace?.readingLocked == true { return nil }
        let menu = super.menu(for: event) ?? NSMenu()
        let location = convert(event.locationInWindow, from: nil)
        if let page = page(for: location, nearest: false), let workspace {
            let point = convert(location, to: page)
            if let hit = workspace.placedSignature(on: page, at: point) {
                contextSignature = hit
                let move = NSMenuItem(title: "移动或缩放此"+hit.item.label, action: #selector(moveHitSignature), keyEquivalent: "")
                move.target = self
                let replace = NSMenuItem(title: hit.item.isPageImage == true ? "替换此图片…" : "替换此签名图片…", action: #selector(replaceHitSignature), keyEquivalent: "")
                replace.target = self; menu.insertItem(replace, at: 0)
                let remove = NSMenuItem(title: "删除此"+hit.item.label, action: #selector(removeHitSignature), keyEquivalent: "")
                remove.target = self
                menu.insertItem(move, at: 0)
                menu.insertItem(remove, at: 1)
                menu.insertItem(.separator(), at: 2)
                return menu
            }
            if let hit = Workspace.visibleAnnotations(on: page).reversed().first(where: { $0.bounds.contains(point) && workspace.cardID(of: $0) == nil }) {
                workspace.selectAnnotation(hit)
                let item = NSMenuItem(title: "删除此标注", action: #selector(deleteHitAnnotation), keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
        }
        if let text = currentSelection?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(title: "摘录到工作区", action: #selector(excerptToBoard), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            let comment = NSMenuItem(title: "添加评论…", action: #selector(commentOnSelection), keyEquivalent: "")
            comment.target = self
            menu.insertItem(comment, at: 1)
            menu.insertItem(.separator(), at: 2)
        }
        if workspace?.store != nil {
            let image = NSMenuItem(title: "框选图片摘录", action: #selector(startImageExcerpt), keyEquivalent: "")
            image.target = self
            menu.insertItem(image, at: 0)
        }
        return menu
    }

    @objc private func commentOnSelection() { beginCommentOnSelection() }
    @objc private func startImageExcerpt() {
        guard let workspace else { return }
        workspace.store?.startReadingRegionCapture(from: workspace)
    }
    @objc private func excerptToBoard() { workspace?.excerptSelection() }
    @objc private func deleteHitAnnotation() { workspace?.deleteAnnotation() }
    private var contextSignature: (layer: SignatureLayer, item: PlacedSignature)?
    @objc private func moveHitSignature() { if let hit = contextSignature { workspace?.beginMovingSignature(hit.item, in: hit.layer) } }
    @objc private func replaceHitSignature() { if let hit = contextSignature { workspace?.replacePlacedSignature(hit.item, in: hit.layer) } }
    @objc private func removeHitSignature() { if let hit = contextSignature { workspace?.removePlacedSignature(hit.item, in: hit.layer) } }

    // MARK: Floating toolbar over a text selection
    private var selectionBar: NSView?
    private var excerptSelections: [PDFSelection] = []
    private var excerptSelectionOverlays: [ReadingSourceOverlay] = []

    func hideSelectionToolbar() { selectionBar?.removeFromSuperview(); selectionBar = nil }

    func beginAddingExcerptSelection(_ selection: PDFSelection) {
        guard let workspace, workspace.canQuickPDFExcerpt, workspace.store != nil else { return }
        if workspace.store?.readingExcerptFeedback?.selectionWorkspaceID == workspace.id {
            workspace.store?.readingExcerptFeedback?.selectionWorkspaceID = nil
        }
        retainExcerptSelection(selection)
        window?.makeFirstResponder(self)
        workspace.status = "可继续拖选其他文字，点「摘录」保存全部选区"
        showExcerptSelectionsToolbar()
    }

    private func retainExcerptSelection(_ selection: PDFSelection) {
        guard let document, !selection.pages.isEmpty,
              selection.pages.allSatisfy({ $0.document === document }),
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let repeated = excerptSelections.contains { previous in
            previous.string == text && previous.pages == selection.pages &&
            selection.pages.allSatisfy { previous.bounds(for: $0) == selection.bounds(for: $0) }
        }
        if !repeated, let retained = selection.copy() as? PDFSelection {
            excerptSelections.append(retained)
            let lines = retained.selectionsByLine()
            for page in retained.pages {
                let rects = lines.filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }
                let overlay = ReadingSourceOverlay(pdfView:self,page:page,rects:rects.isEmpty ? [retained.bounds(for:page)] : rects,color:.systemBlue)
                excerptSelectionOverlays.append(overlay)
                addSubview(overlay, positioned: .above, relativeTo: nil)
            }
        }
        clearSelection()
    }

    func cancelExcerptSelections() {
        guard !excerptSelections.isEmpty else { return }
        excerptSelections.removeAll()
        excerptSelectionOverlays.forEach { $0.removeFromSuperview() }
        excerptSelectionOverlays.removeAll()
        hideSelectionToolbar()
        clearSelection()
    }

    func saveExcerptSelections() {
        guard let workspace, workspace.canQuickPDFExcerpt, let store = workspace.store,
              !excerptSelections.isEmpty else { return }
        guard !store.journal.unreadable else { workspace.error = store.journal.error; return }
        let sections = excerptSelections.compactMap { workspace.readingExcerpt(from: $0) }
        guard sections.count == excerptSelections.count, var record = sections.first else {
            workspace.status = "无法读取选区，请重新选择文字"
            return
        }
        for section in sections.dropFirst() { record.appendExcerpt(section) }
        guard store.saveReadingExcerpt(record, offeringMoreFrom: workspace.id) else { return }
        workspace.preparePDFExcerpt()
        workspace.status = store.readingExcerptFeedback?.message ?? "摘录已保存"
    }

    private func showExcerptSelectionsToolbar() {
        guard let anchor = excerptSelections.last else { return }
        showSelectionToolbar(PDFSelectionActions(
            editable: false, compact: bounds.width < 340, excerpt: { [weak self] in self?.saveExcerptSelections() },
            selectionCount: excerptSelections.count, cancelSelection: { [weak self] in self?.cancelExcerptSelections() },
            note: {}, copy: {}, mark: { _, _, _ in }
        ), near: anchor)
    }

    /// Handles the final text selection once PDFKit has processed the mouse release.
    func finishTextSelection() {
        hideSelectionToolbar()
        if !excerptSelections.isEmpty {
            if let selection = currentSelection { retainExcerptSelection(selection) }
            showExcerptSelectionsToolbar()
            return
        }
        guard commentEditor == nil, let workspace, workspace.tool == .select, let selected = currentSelection,
              !(selected.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selected.pages.isEmpty else { return }
        if workspace.awaitsPDFExcerptText {
            workspace.savePDFTextExcerpt(selected)
            return
        }
        let match = workspace.readingExcerpt(from:selected,trackVisual:false).flatMap { workspace.store?.existingReadingExcerpt($0) }
        let copySelection: (ReadingExcerptCopyFormat) -> Void = { [weak self, weak workspace] format in
            guard let workspace, var capture = workspace.readingExcerpt(from:selected,trackVisual:false) else { return }
            if let text = selected.string { capture.quote = text }
            format.copy(capture,defaults:workspace.readingDefaults)
            self?.hideSelectionToolbar()
        }
        let noteTarget = workspace.store?.citationNoteTarget
        let toolbar = PDFSelectionActions(
            editable: !workspace.readingLocked, compact: bounds.width < 340,
            excerpt: { [weak workspace] in workspace?.savePDFTextExcerpt(selected) },
            addSelection: workspace.store != nil ? { [weak self] in self?.beginAddingExcerptSelection(selected) } : nil,
            note: { [weak self, weak workspace] in
                if let workspace, let record = workspace.readingExcerpt(from: selected) {
                    workspace.store?.startNoteFromExcerpt(record)
                }
                self?.hideSelectionToolbar()
            },
            insertInNote: noteTarget != nil ? { [weak self, weak workspace] in
                guard let workspace else { return }
                if workspace.store?.insertPDFSelectionInNote(from:workspace,selection:selected,expectedNoteID:noteTarget?.id) == true { self?.hideSelectionToolbar() }
            } : nil,
            noteTargetTitle:noteTarget?.displayTitle,
            copy: { [weak workspace] in copySelection(.preferred(workspace?.readingDefaults ?? .standard)) },
            copyAs:copySelection,
            openExisting:match.map { record in { [weak self, weak workspace] in
                workspace?.store?.revealCapturedExcerpt(record,message:"已打开已有摘录")
                self?.hideSelectionToolbar()
            } },
            comment: { [weak self] in self?.beginCommentOnSelection(selected) },
            mark: { [weak self, weak workspace] style, color, annotate in
                guard let workspace, !workspace.readingLocked else { return }
                if let color { workspace.markupColor = color }
                if annotate {
                    self?.beginCommentOnSelection(selected, highlight: true)
                    return
                }
                if self?.currentSelection == nil { self?.setCurrentSelection(selected,animate:false) }
                workspace.mark(style: style, color: workspace.markupColor)
                self?.hideSelectionToolbar()
            }
        )
        showSelectionToolbar(toolbar, near: selected)
    }

    private func showSelectionToolbar(_ toolbar: PDFSelectionActions, near selection: PDFSelection) {
        hideSelectionToolbar()
        let host = NSHostingView(rootView: toolbar)
        host.frame.size = host.fittingSize
        positionSelectionToolbar(host, near: selection)
        addSubview(host)
        selectionBar = host
    }

    private func positionSelectionToolbar(_ host: NSView, near selection: PDFSelection) {
        guard let page = selection.pages.last else { return }
        let area = convert(selection.bounds(for: page), from: page)
        var origin = CGPoint(x: area.midX - host.frame.width / 2, y: area.maxY + 5)
        if !area.intersects(bounds) && !excerptSelections.isEmpty {
            origin = CGPoint(x: bounds.midX - host.frame.width / 2, y: bounds.maxY - host.frame.height - 6)
        } else if origin.y + host.frame.height > bounds.maxY {
            origin.y = area.minY - host.frame.height - 5
        }
        origin.x = min(max(bounds.minX, origin.x), max(bounds.minX, bounds.maxX - host.frame.width))
        origin.y = min(max(bounds.minY, origin.y), max(bounds.minY, bounds.maxY - host.frame.height))
        host.frame.origin = origin
    }

    func beginCommentOnSelection(_ specific: PDFSelection? = nil, highlight: Bool = false) {
        guard let workspace, !workspace.readingLocked, !workspace.busy, placement == nil else { return }
        guard let source = specific ?? currentSelection, let page = source.pages.last,
              let quote = source.string, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            workspace.status = "请先选中文字，或用批注工具点击页面添加评论"
            return
        }
        let anchor = source.bounds(for: page).intersection(page.bounds(for: .cropBox))
        guard !anchor.isEmpty, !anchor.isNull else { return }
        openCommentEditor(page: page, anchor: anchor, quote: quote, highlight: highlight ? source : nil)
    }

    private func comment(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first {
            $0.shouldDisplay && $0.bounds.contains(point) && (PDFInlineComment.isCard($0) || $0.type == "Text")
        }
    }

    private func openCommentEditor(page: PDFPage, anchor: CGRect, quote: String? = nil,
                                   existing: PDFAnnotation? = nil, highlight: PDFSelection? = nil) {
        guard commentEditor == nil, let workspace, !workspace.readingLocked, !workspace.busy, document === page.document,
              let window, window.isVisible else { return }
        hideSelectionToolbar()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: PDFInlineCommentEditor(
            text: existing?.contents ?? "",
            style: existing.map(PDFInlineComment.style(of:)) ?? PDFCommentStyle(),
            editing: existing != nil, supportsStyle: existing.map(PDFInlineComment.isCard) ?? true,
            save: { [weak self, weak workspace] text, style in
                guard let self, let workspace, self.workspace === workspace else { return }
                if workspace.saveInlineComment(text, page: page, anchor: anchor, quote: quote,
                                               existing: existing, highlight: highlight, style: style) {
                    self.dismissCommentEditor()
                    self.clearSelection()
                    self.documentView?.needsDisplay = true
                    self.needsDisplay = true
                } else {
                    self.dismissCommentEditor()
                    workspace.status = "评论未保存，页面已变化或当前无法编辑"
                }
            },
            cancel: { [weak self] in self?.dismissCommentEditor() }
        ))
        let raw = convert(existing?.bounds ?? anchor, from: page)
        let visible = raw.intersection(bounds.insetBy(dx: 4, dy: 4))
        guard !visible.isNull, !visible.isEmpty else { return }
        commentEditor = popover
        popover.show(relativeTo: visible, of: self, preferredEdge: .maxX)
    }

    private func openClickedComment(_ annotation: PDFAnnotation, on page: PDFPage, event: NSEvent) {
        guard annotation.page === page, let anchor = PDFInlineComment.anchor(of: annotation) else { return }
        let position = convert(event.locationInWindow, from: nil)
        guard annotation.bounds.contains(convert(position, to: page)) else { return }
        openCommentEditor(page: page, anchor: anchor, existing: annotation)
    }

    func dismissCommentEditor() {
        let editor = commentEditor
        commentEditor = nil
        editor?.close()
    }

    private func captureRegion(_ rect: CGRect, on page: PDFPage) {
        guard let workspace, document === page.document, rect.width > 8, rect.height > 8 else { return }
        let pageRect = convert(rect, to: page).intersection(page.bounds(for: .cropBox))
        guard !pageRect.isNull, !pageRect.isEmpty else { return }
        do {
            let png = try PDFImageExcerpt.png(for: pageRect, on: page)
            let size = page.rotation % 180 == 0 ? pageRect.size : CGSize(width: pageRect.height, height: pageRect.width)
            workspace.excerptRegion(imageData: png, size: size, page: page, pageRect: pageRect)
            if !workspace.keepsReadingRegionCapture { workspace.selectTool(.select) }
        } catch {
            workspace.error = error.localizedDescription
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, let event = NSApp?.currentEvent, event.type == .leftMouseDown,
              let window, event.window === window, let workspace, !workspace.busy else { return hit }
        if let selectionBar, hit === selectionBar || hit.isDescendant(of:selectionBar) { return hit }
        let location = convert(event.locationInWindow,from:nil)
        if let page = page(for: location, nearest: false), placement == nil {
            if workspace.tool == .region { return self }
            if !workspace.readingLocked {
                if workspace.tool == .note { return self }
                if (workspace.tool == .select || workspace.tool == .edit),
                   comment(at: convert(location, to: page), on: page) != nil {
                    return self
                }
            }
        }
        // PDFKit subviews may receive the press. Keep a press on the selected glyphs with the drag source.
        return canDragSelection(at:location,event:event,workspace:workspace) ? self : hit
    }

    private func canDragSelection(at location: NSPoint, event: NSEvent, workspace: Workspace) -> Bool {
        guard workspace.tool == .select, workspace.store?.acceptsPDFExcerptDrop == true,
              placement == nil, event.clickCount == 1,
              event.modifierFlags.intersection([.shift,.control,.option,.command]).isEmpty,
              let page = page(for:location,nearest:false),
              let selected = currentSelection,
              let text = selected.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              selected.pages.contains(where:{ $0 === page }) else { return false }
        let point = convert(location,to:page)
        if let annotation = page.annotation(at:point),
           ["Widget","Link","FreeText","Text"].contains(annotation.type ?? "") { return false }
        let lines = selected.selectionsByLine().filter { $0.pages.contains(where:{ $0 === page }) }
        return (lines.isEmpty ? [selected] : lines).contains {
            $0.bounds(for:page).insetBy(dx:-1,dy:-1).contains(point)
        }
    }

    private func startExcerptDrag(with event: NSEvent) {
        guard let workspace, let store = workspace.store, let selection = currentSelection,
              let record = workspace.readingExcerpt(from:selection),
              let drag = store.beginPDFExcerptDrag(record,from:workspace) else { return }
        let item = NSDraggingItem(pasteboardWriter:drag.pasteboardItem())
        let preview = NSImage(size:NSSize(width:230,height:40),flipped:false) { rect in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect:rect,xRadius:7,yRadius:7).fill()
            let text = String(record.quote.split(whereSeparator:\.isNewline).first?.prefix(36) ?? "")
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in:rect.insetBy(dx:10,dy:11),
                                    withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
            return true
        }
        let point = convert(event.locationInWindow,from:nil)
        item.setDraggingFrame(NSRect(x:point.x-12,y:point.y-20,width:230,height:40),contents:preview)
        let source = PDFExcerptDragSource(store:store,token:drag.token)
        excerptDragSource = source
        beginDraggingSession(with:[item],event:event,source:source).animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseDown(with event: NSEvent) {
        pressedComment = nil
        excerptDragStart = nil
        hideSelectionToolbar()
        if let workspace { workspace.store?.focus(workspace) }
        guard let workspace, !workspace.busy else { super.mouseDown(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
        if canDragSelection(at:location,event:event,workspace:workspace) {
            excerptDragStart = location
            pressedCard = nil
            return
        }
        if workspace.readingLocked,workspace.tool != .region {
            if let page = page(for:location,nearest:false),let hit = page.annotation(at:convert(location,to:page)),["Widget","FreeText","Text"].contains(hit.type ?? "") { return }
            super.mouseDown(with:event);return
        }
        // Double-clicking a signature placed in this session picks it up to move or resize it.
        if event.clickCount == 2, placement == nil, workspace.tool == .select || workspace.tool == .edit,
           let page = page(for: location, nearest: false),
           let hit = workspace.placedSignature(on: page, at: convert(location, to: page)) {
            workspace.beginMovingSignature(hit.item, in: hit.layer)
            return
        }
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        if placement == nil, workspace.tool == .select || workspace.tool == .edit || workspace.tool == .note,
           let hit = comment(at: point, on: page) {
            if PDFInlineComment.isCard(hit) {
                if workspace.tool != .edit {
                    pressedComment = (page, hit)
                    return
                }
            } else {
                if event.clickCount == 2 {
                    openCommentEditor(page: page, anchor: hit.bounds, existing: hit)
                    return
                }
                if workspace.tool == .note { return }
            }
        }
        switch workspace.tool {
        case .select:
            if page.annotations.contains(where: { $0.type == "Widget" && $0.bounds.contains(point) }) {
                workspace.showPDFForms = true
                return
            }
            // Route editable annotations through our tracked editor so edits are recoverable.
            if let hit = page.annotations.reversed().first(where: { ["FreeText", "Text"].contains($0.type ?? "") && $0.bounds.contains(point) }) {
                workspace.selectAnnotation(hit)
                workspace.tool = .edit
                return
            }
            if let hit = page.annotation(at: point), let id = workspace.cardID(of: hit) { pressedCard = id; pressMoved = false } else { pressedCard = nil }
            super.mouseDown(with: event)
        case .edit:
            let hit = Workspace.visibleAnnotations(on: page).reversed().first { $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
            workspace.selectAnnotation(hit)
            moving = hit
            drawingPage = page
            moveStart = point
            originalOrigin = hit?.bounds.origin ?? .zero
            didMove = false
        case .note:
            openCommentEditor(page: page, anchor: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
        case .textBox:
            let text: String
            if workspace.note.isEmpty {
                guard let entered = AnnotationText.ask(note: false) else { return }
                text = entered
            } else {
                text = workspace.note
            }
            let height = AnnotationText.boxHeight(for: text)
            let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - height, width: 220, height: height), forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: 14)
            annotation.fontColor = NSColor(workspace.annotationColor)
            annotation.color = .clear
            page.addAnnotation(annotation)
            workspace.recordAnnotationsAdded([annotation])
            needsDisplay = true
        case .pen, .line, .arrow, .rectangle, .ellipse, .signature:
            workspace.drawingInProgress = true
            // Nothing is recorded until the stroke ends; mouseDown no longer serializes the document.
            drawingPage = page
            points = [point]
            provisional = nil
        case .eraser:
            // Removes the topmost mark whose box holds the click; undo brings it back.
            if let hit = Workspace.visibleAnnotations(on: page).reversed().first(where: { $0.bounds.insetBy(dx: -3, dy: -3).contains(point) }) {
                workspace.selectAnnotation(hit)
                workspace.deleteAnnotation()
                needsDisplay = true
            }
        case .region:
            regionStart = location
            regionPage = page
            regionView.frame = CGRect(origin: location, size: .zero)
            regionView.isHidden = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedComment != nil { return }
        if let start = excerptDragStart {
            let point = convert(event.locationInWindow,from:nil)
            if hypot(point.x-start.x,point.y-start.y) >= 5 {
                excerptDragStart = nil
                startExcerptDrag(with:event)
            }
            return
        }
        if pressedCard != nil { pressMoved = true }
        if let start = regionStart, let page = regionPage {
            let current = convert(event.locationInWindow, from: nil)
            let requested = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                   width: abs(current.x - start.x), height: abs(current.y - start.y))
            let clipped = requested.intersection(convert(page.bounds(for: .cropBox), from: page))
            regionView.frame = clipped.isNull ? .zero : clipped
            return
        }
        if let moving, let page = drawingPage, let workspace {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            if !didMove {
                let distance = hypot(point.x - moveStart.x, point.y - moveStart.y) * scaleFactor
                if PDFInlineComment.isCard(moving), distance < 3 { return }
                pendingMove = workspace.beginAnnotationEdit([moving])
                didMove = true
            }
            moving.bounds.origin = CGPoint(x: originalOrigin.x + point.x - moveStart.x, y: originalOrigin.y + point.y - moveStart.y)
            needsDisplay = true
            return
        }
        guard let workspace, workspace.tool.draws, let page = drawingPage else { super.mouseDragged(with: event); return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        points.append(point)

        let style = workspace.drawingStrokeStyle
        let stroke = workspace.tool == .pen && !workspace.penHighlighter ? workspace.markerTouch.strokePoints(points) : points
        let color: NSColor = workspace.tool == .signature ? .black : NSColor(workspace.annotationColor)
        let signature = workspace.tool == .signature
        let drawn = signature ? PenStyle(width: 1.6, alpha: 1) : style
        guard let annotation = AnnotationShapes.make(tool: workspace.tool, points: stroke, style: drawn, color: color, fill: workspace.shapeFill,
                                                       constrained: event.modifierFlags.contains(.shift), dashed: workspace.lineDashed) else { return }
        if signature { annotation.userName = "KongFolio Signature" }
        provisional = annotation
        strokePreview.annotation = annotation
        strokePreview.page = page
        strokePreview.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedComment {
            self.pressedComment = nil
            openClickedComment(pressedComment.annotation, on: pressedComment.page, event: event)
            return
        }
        if excerptDragStart != nil {
            excerptDragStart = nil
            clearSelection()
            return
        }
        // The selection is final only after PDFView has handled the release.
        defer { DispatchQueue.main.async { [weak self] in self?.finishTextSelection() } }
        if let id = pressedCard {
            pressedCard = nil
            super.mouseUp(with: event)
            if !pressMoved { workspace?.focusCard(id) }
            return
        }
        if regionStart != nil {
            let rect = regionView.frame
            let page = regionPage
            resetExcerptRegion()
            if let page, workspace?.tool == .region { captureRegion(rect, on: page) }
            return
        }
        if let moving {
            let completedDrag = didMove
            let page = drawingPage
            if completedDrag { workspace?.commitAnnotationEdit(pendingMove) }
            self.moving = nil
            pendingMove = []
            drawingPage = nil
            didMove = false
            if !completedDrag, let page, PDFInlineComment.isCard(moving) {
                openClickedComment(moving, on: page, event: event)
            }
            return
        }
        if drawingPage != nil {
            workspace?.drawingInProgress = false
            if let provisional, let page = drawingPage {
                page.addAnnotation(provisional)
                workspace?.recordAnnotationsAdded([provisional])
            }
            strokePreview.annotation = nil
            strokePreview.needsDisplay = true
            provisional = nil
            points = []
            drawingPage = nil
            needsDisplay = true
        } else {
            super.mouseUp(with: event)
        }
    }
}

/// Keeps the two comparison panes on the same page when syncing is on.
@MainActor final class ComparisonSync: ObservableObject {
    @Published var enabled = true
    @Published var page = 0
}

struct ComparisonCanvas: NSViewRepresentable {
    let document: PDFDocument
    @ObservedObject var sync: ComparisonSync

    func makeNSView(context: Context) -> PDFView {
        let view = ManagedPDFView()
        view.autoScales = true
        view.document = document
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak sync] _ in
            Task { @MainActor in
                guard let view, let sync, sync.enabled, let page = view.currentPage, let index = view.document?.index(for: page), index != NSNotFound, index != sync.page else { return }
                sync.page = index
            }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document { nsView.document = document }
        guard sync.enabled, let current = nsView.currentPage, nsView.document?.index(for: current) != sync.page,
              let target = document.page(at: min(sync.page, document.pageCount - 1)) else { return }
        nsView.go(to: target)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.observer = nil
        view.clearSelection(); view.delegate = nil; view.document = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}


/// The signature as it will be stamped: drag to move, drag the corner to resize (the aspect ratio is kept).
final class SignaturePlacementView: NSView {
    let aspect: CGFloat
    private let image: CGImage
    private var dragging = false
    private var resizing = false
    private var lastPoint = CGPoint.zero

    init(image: CGImage) {
        self.image = image
        aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var handle: CGRect { CGRect(x: bounds.maxX - 18, y: 0, width: 18, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.08).cgColor)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(bounds.insetBy(dx: 0.75, dy: 0.75))
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(handle)
    }

    override func resetCursorRects() {
        addCursorRect(handle, cursor: .crosshair)
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        resizing = handle.contains(local)
        dragging = !resizing
        lastPoint = superview?.convert(event.locationInWindow, from: nil) ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        if resizing {
            let width = min(max(40, point.x - frame.minX), superview.bounds.width)
            let height = width / aspect
            frame = CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
        } else if dragging {
            frame = frame.offsetBy(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
        }
        lastPoint = point
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false; resizing = false
        if let pdfView = superview as? DrawingPDFView {
            pdfView.workspace?.updatePageImageSize()
            if event.clickCount == 2 { pdfView.workspace?.confirmSignaturePlacement() }
        }
    }
}


private final class ReadingSourceOverlay: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    let rects: [CGRect]
    let color: NSColor

    init(pdfView:PDFView,page:PDFPage,rects:[CGRect],color:NSColor) {
        self.pdfView = pdfView
        self.page = page
        self.rects = rects
        self.color = color
        super.init(frame:pdfView.bounds)
        autoresizingMask = [.width,.height]
    }

    required init?(coder:NSCoder) { nil }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect:NSRect) {
        guard let pdfView, let page, pdfView.document === page.document else { return }
        color.withAlphaComponent(0.23).setFill()
        color.withAlphaComponent(0.8).setStroke()
        let crop = page.bounds(for:.cropBox)
        for rect in rects {
            let clipped = rect.intersection(crop)
            guard !clipped.isEmpty else { continue }
            let frame = pdfView.convert(clipped,from:page)
            guard frame.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect:frame,xRadius:2,yRadius:2)
            path.lineWidth = 1.5
            path.fill()
            path.stroke()
        }
    }
}

/// A live stroke is painted above PDFKit. PDF page contents change once, on mouse-up.
@MainActor final class StrokePreviewView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    var annotation: PDFAnnotation?
    init(pdfView: PDFView) { self.pdfView = pdfView; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let page, let annotation, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = convert(pdfView.convert(CGPoint.zero, from: page), from: pdfView)
        let x = convert(pdfView.convert(CGPoint(x: 1, y: 0), from: page), from: pdfView)
        let y = convert(pdfView.convert(CGPoint(x: 0, y: 1), from: page), from: pdfView)
        context.saveGState()
        context.concatenate(CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y))
        context.clip(to: page.bounds(for: .cropBox))
        annotation.draw(with: .cropBox, in: context)
        context.restoreGState()
    }
}

final class ReadingRulerOverlay: NSView {
    weak var pdfView: DrawingPDFView?
    init(pdfView:DrawingPDFView) { self.pdfView = pdfView; super.init(frame:.zero) }
    required init?(coder:NSCoder) { fatalError("not used") }
    private var guideRect: CGRect? {
        guard let view = pdfView, let w = view.workspace, w.readingRuler.enabled, let page = view.currentPage else { return nil }
        let box = view.convert(page.bounds(for:.cropBox),from:page), ruler = w.readingRuler
        if ruler.direction == .vertical { let width = box.width*ruler.thickness; return CGRect(x:box.minX+box.width*ruler.position-width/2,y:box.minY,width:width,height:box.height).intersection(bounds) }
        let height = box.height*ruler.thickness
        return CGRect(x:box.minX,y:box.maxY-box.height*ruler.position-height/2,width:box.width,height:height).intersection(bounds)
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let rect = guideRect, let ruler = pdfView?.workspace?.readingRuler else { return }
        NSColor.systemYellow.withAlphaComponent(ruler.opacity).setFill(); NSBezierPath(rect:rect).fill()
        NSColor.systemOrange.withAlphaComponent(0.6).setStroke(); let border = NSBezierPath(rect:rect); border.lineWidth = 1; border.stroke()
        NSColor.systemOrange.withAlphaComponent(0.75).setFill()
        let handle = ruler.direction == .vertical ? CGRect(x:rect.minX,y:rect.maxY-14,width:rect.width,height:14) : CGRect(x:rect.minX,y:rect.minY,width:14,height:rect.height)
        NSBezierPath(roundedRect:handle,xRadius:3,yRadius:3).fill()
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard pdfView?.workspace?.tool == .select, let rect = guideRect, let ruler = pdfView?.workspace?.readingRuler else { return nil }
        let handle = ruler.direction == .vertical ? CGRect(x:rect.minX,y:rect.maxY-18,width:rect.width,height:18) : CGRect(x:rect.minX,y:rect.minY,width:18,height:rect.height)
        let modifier = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        return handle.insetBy(dx:-3,dy:-3).contains(point) || (modifier && rect.contains(point)) ? self : nil
    }
    override func mouseDown(with event:NSEvent) { move(event) }
    override func mouseDragged(with event:NSEvent) { move(event) }
    private func move(_ event:NSEvent) {
        guard let view = pdfView, let w = view.workspace, let page = view.currentPage else { return }
        let point = convert(event.locationInWindow,from:nil), box = view.convert(page.bounds(for:.cropBox),from:page)
        let value = w.readingRuler.direction == .vertical ? (point.x-box.minX)/max(1,box.width) : (box.maxY-point.y)/max(1,box.height)
        w.readingRuler.position = min(1,max(0,value)); needsDisplay = true
    }
}
