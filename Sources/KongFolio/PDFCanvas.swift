import SwiftUI
import PDFKit

struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    func makeNSView(context: Context) -> DrawingPDFView {
        let view = DrawingPDFView(); view.workspace = workspace; view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.backgroundColor = .windowBackgroundColor
        workspace.pdfView = view
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak workspace] _ in
            Task { @MainActor in
                guard let view, let workspace, let page = view.currentPage, view.document === workspace.document else { return }
                let index = workspace.document.index(for: page)
                if index != NSNotFound && index != workspace.selection { workspace.selection = index; if workspace.selectedPages.count <= 1 { workspace.selectedPages = [index] }; workspace.resetImage(); workspace.scheduleRecovery() }
            }
        }
        return view
    }
    func updateNSView(_ view: DrawingPDFView, context: Context) {
        let replaced = view.document !== workspace.document
        let display: PDFDisplayMode
        switch workspace.readingLayout {
        case .single: display = .singlePage
        case .twoUp: display = .twoUp
        case .continuous: display = .singlePageContinuous
        }
        let layoutChanged = view.displayMode != display
        if replaced { view.document = workspace.document }
        if layoutChanged { view.displayMode = display }
        if replaced || layoutChanged || context.coordinator.navigation != workspace.navigationToken {
            if let scale = workspace.readingScale { view.autoScales = false; view.scaleFactor = scale } else { view.autoScales = true }
            if let page = workspace.page {
                if let point = workspace.readingPoint { view.go(to: PDFDestination(page: page, at: point)) }
                else { view.go(to: page) }
            }
            context.coordinator.navigation = workspace.navigationToken
        }
        if context.coordinator.revision != workspace.revision { view.layoutDocumentView(); context.coordinator.revision = workspace.revision }
        if context.coordinator.scrollObserver == nil, let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            context.coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak workspace] _ in
                Task { @MainActor in workspace?.captureReadingPosition() }
            }
        }
        view.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {
        var navigation: UUID?
        var scrollObserver: NSObjectProtocol?
        var revision: UUID?
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    }
}
final class DrawingPDFView: PDFView, SignaturePlacing {
    weak var workspace: Workspace?
    private var points: [CGPoint] = []
    private weak var drawingPage: PDFPage?
    private var provisional: PDFAnnotation?
    private var moving: PDFAnnotation?
    private var pendingMove: [PendingAnnotationEdit] = []
    private var moveStart = CGPoint.zero
    private var originalOrigin = CGPoint.zero
    private var didMove = false
    /// The card of an excerpt colour that was pressed (a click without dragging shows the card in the workspace).
    private var pressedCard: UUID?
    private var pressMoved = false
    /// Rubber band of the region excerpt tool.
    private var regionStart: CGPoint?
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

    func signaturePlacement() -> (page: PDFPage, rect: CGRect)? {
        guard let overlay = placement,
              let page = page(for: CGPoint(x: overlay.frame.midX, y: overlay.frame.midY), nearest: true) else { return nil }
        return (page, convert(overlay.frame, to: page))
    }

    func endSignaturePlacement() {
        placement?.removeFromSuperview()
        placement = nil
    }

    override func keyDown(with event: NSEvent) {
        if placement != nil, let workspace {
            switch event.keyCode {
            case 36, 76: workspace.confirmSignaturePlacement(); return
            case 53: workspace.cancelSignaturePlacement(); return
            default: break
            }
        }
        if let workspace, workspace.showAnnotationBar, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
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
        let menu = super.menu(for: event) ?? NSMenu()
        let location = convert(event.locationInWindow, from: nil)
        if let page = page(for: location, nearest: false), let workspace {
            let point = convert(location, to: page)
            if let hit = workspace.placedSignature(on: page, at: point) {
                contextSignature = hit
                let move = NSMenuItem(title: "移动或缩放此签名", action: #selector(moveHitSignature), keyEquivalent: "")
                move.target = self
                let remove = NSMenuItem(title: "删除此签名", action: #selector(removeHitSignature), keyEquivalent: "")
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
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func excerptToBoard() { workspace?.excerptSelection() }
    @objc private func deleteHitAnnotation() { workspace?.deleteAnnotation() }
    private var contextSignature: (layer: SignatureLayer, item: PlacedSignature)?
    @objc private func moveHitSignature() { if let hit = contextSignature { workspace?.beginMovingSignature(hit.item, in: hit.layer) } }
    @objc private func removeHitSignature() { if let hit = contextSignature { workspace?.removePlacedSignature(hit.item, in: hit.layer) } }

    // MARK: Floating toolbar over a text selection
    private var selectionBar: NSView?

    func hideSelectionToolbar() { selectionBar?.removeFromSuperview(); selectionBar = nil }

    /// Shows the marking buttons next to the selected text once the mouse is released.
    private func showSelectionToolbar() {
        hideSelectionToolbar()
        guard let workspace, workspace.tool == .select, let selected = currentSelection,
              !(selected.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selected.pages.last else { return }
        let area = convert(selected.bounds(for: page), from: page)
        var buttons: [NSView] = MarkupColor.allCases.map { color in
            ActionButton(image: Self.dot(color.nsColor), tip: "高亮（\(color.rawValue)）") { [weak self] in
                workspace.markupColor = color
                workspace.mark(style: .highlight, color: color); self?.hideSelectionToolbar()
            }
        }
        buttons += [
            ActionButton(symbol: "underline", tip: "下划线") { [weak self] in workspace.mark(style: .underline, color: workspace.markupColor); self?.hideSelectionToolbar() },
            ActionButton(symbol: "strikethrough", tip: "删除线") { [weak self] in workspace.mark(style: .strikeOut, color: workspace.markupColor); self?.hideSelectionToolbar() },
            ActionButton(symbol: "text.bubble", tip: "高亮并加批注") { [weak self] in workspace.mark(style: .highlight, color: workspace.markupColor, annotate: true); self?.hideSelectionToolbar() },
            ActionButton(symbol: "square.and.arrow.down.on.square", tip: "摘录到工作区") { [weak self] in workspace.excerptSelection(); self?.hideSelectionToolbar() },
        ]
        let stack = NSStackView(views: buttons)
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        stack.layer?.cornerRadius = 8
        stack.layer?.borderWidth = 0.5
        stack.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.frame.size = stack.fittingSize
        var origin = CGPoint(x: area.midX - stack.frame.width / 2, y: area.maxY + 6)
        if origin.y + stack.frame.height > bounds.maxY { origin.y = area.minY - stack.frame.height - 6 }
        origin.x = min(max(4, origin.x), max(4, bounds.maxX - stack.frame.width - 4))
        origin.y = min(max(4, origin.y), max(4, bounds.maxY - stack.frame.height - 4))
        stack.frame.origin = origin
        addSubview(stack)
        selectionBar = stack
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill(); return true
        }
    }

    /// Captures what is on screen inside the dragged rectangle and sends it to the workspace.
    private func captureRegion(_ rect: CGRect) {
        guard let workspace, rect.width > 8, rect.height > 8,
              let page = page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: true),
              let rep = bitmapImageRepForCachingDisplay(in: rect) else { return }
        cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        workspace.excerptRegion(imageData: png, size: rect.size, page: page, pageRect: convert(rect, to: page))
        workspace.tool = .select
    }

    override func mouseDown(with event: NSEvent) {
        hideSelectionToolbar()
        if let workspace { workspace.store?.focus(workspace) }
        guard let workspace, !workspace.busy else { super.mouseDown(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
        // Double-clicking a signature placed in this session picks it up to move or resize it.
        if event.clickCount == 2, placement == nil, workspace.tool == .select || workspace.tool == .edit,
           let page = page(for: location, nearest: false),
           let hit = workspace.placedSignature(on: page, at: convert(location, to: page)) {
            workspace.beginMovingSignature(hit.item, in: hit.layer)
            return
        }
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        switch workspace.tool {
        case .select:
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
        case .note, .textBox:
            let isNote = workspace.tool == .note
            // The text is asked for right here, unless one was already typed in the side panel.
            let text: String
            if workspace.note.isEmpty {
                guard let entered = AnnotationText.ask(note: isNote) else { return }
                text = entered
            } else {
                text = workspace.note
            }
            let height: CGFloat = isNote ? 28 : AnnotationText.boxHeight(for: text)
            let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - height, width: isNote ? 28 : 220, height: height), forType: isNote ? .text : .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: 14)
            annotation.fontColor = isNote ? .black : NSColor(workspace.annotationColor)
            annotation.color = isNote ? .systemYellow : .clear
            page.addAnnotation(annotation)
            workspace.recordAnnotationsAdded([annotation])
            needsDisplay = true
        case .pen, .line, .arrow, .rectangle, .ellipse, .signature:
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
            regionView.frame = CGRect(origin: location, size: .zero)
            regionView.isHidden = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedCard != nil { pressMoved = true }
        if let start = regionStart {
            let current = convert(event.locationInWindow, from: nil)
            regionView.frame = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
            return
        }
        if let moving, let page = drawingPage, let workspace {
            if !didMove { pendingMove = workspace.beginAnnotationEdit([moving]); didMove = true }
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            moving.bounds.origin = CGPoint(x: originalOrigin.x + point.x - moveStart.x, y: originalOrigin.y + point.y - moveStart.y)
            needsDisplay = true
            return
        }
        guard let workspace, workspace.tool.draws, let page = drawingPage else { super.mouseDragged(with: event); return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        points.append(point)
        if let provisional { page.removeAnnotation(provisional) }
        let style = PenStyle.make(width: workspace.penWidth, highlighter: workspace.penHighlighter, arrow: workspace.tool != .pen)
        let color: NSColor = workspace.tool == .signature ? .black : NSColor(workspace.annotationColor)
        let signature = workspace.tool == .signature
        let drawn = signature ? PenStyle(width: 1.6, alpha: 1) : style
        guard let annotation = AnnotationShapes.make(tool: workspace.tool, points: points, style: drawn, color: color, fill: workspace.shapeFill,
                                                       constrained: event.modifierFlags.contains(.shift), dashed: workspace.lineDashed) else { return }
        if signature { annotation.userName = "KongFolio Signature" }
        page.addAnnotation(annotation)
        provisional = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // The selection is final only after PDFView has handled the release.
        defer { DispatchQueue.main.async { [weak self] in self?.showSelectionToolbar() } }
        if let id = pressedCard {
            pressedCard = nil
            super.mouseUp(with: event)
            if !pressMoved { workspace?.focusCard(id) }
            return
        }
        if regionStart != nil {
            let rect = regionView.frame
            regionStart = nil
            regionView.isHidden = true
            regionView.frame = .zero
            captureRegion(rect)
            return
        }
        if moving != nil {
            if didMove { workspace?.commitAnnotationEdit(pendingMove) }
            moving = nil
            pendingMove = []
            drawingPage = nil
            didMove = false
            return
        }
        if drawingPage != nil {
            if let provisional { workspace?.recordAnnotationsAdded([provisional]) }
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
        let view = PDFView()
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
        if event.clickCount == 2, let pdfView = superview as? DrawingPDFView { pdfView.workspace?.confirmSignaturePlacement() }
    }
}


/// A small borderless button that runs a closure; used by the floating selection toolbar.
final class ActionButton: NSButton {
    private let handler: () -> Void

    init(image: NSImage, tip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 24))
        self.image = image
        toolTip = tip
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(run)
    }

    convenience init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), tip: tip, handler: handler)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
