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
final class DrawingPDFView: PDFView {
    weak var workspace: Workspace?
    private var points: [CGPoint] = []
    private weak var drawingPage: PDFPage?
    private var provisional: PDFAnnotation?
    private var moving: PDFAnnotation?
    private var pendingMove: [PendingAnnotationEdit] = []
    private var moveStart = CGPoint.zero
    private var originalOrigin = CGPoint.zero
    private var didMove = false
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let text = currentSelection?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(title: "摘录到工作区", action: #selector(excerptToBoard), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func excerptToBoard() { workspace?.excerptSelection() }

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
        guard let workspace, !workspace.busy else { super.mouseDown(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
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
            let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 40, width: isNote ? 28 : 220, height: isNote ? 28 : 50), forType: isNote ? .text : .freeText, withProperties: nil)
            annotation.contents = workspace.note.isEmpty ? "双击批注查看；右侧输入文字后可继续添加" : workspace.note
            annotation.font = NSFont.systemFont(ofSize: 14)
            annotation.fontColor = .black
            annotation.color = isNote ? .systemYellow : .clear
            page.addAnnotation(annotation)
            workspace.recordAnnotationsAdded([annotation])
            needsDisplay = true
        case .pen, .arrow, .signature:
            // Nothing is recorded until the stroke ends; mouseDown no longer serializes the document.
            drawingPage = page
            points = [point]
            provisional = nil
        case .region:
            regionStart = location
            regionView.frame = CGRect(origin: location, size: .zero)
            regionView.isHidden = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
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
        let annotation: PDFAnnotation
        if workspace.tool == .arrow, let start = points.first {
            let bounds = CGRect(x: min(start.x, point.x) - 3, y: min(start.y, point.y) - 3, width: abs(point.x - start.x) + 6, height: abs(point.y - start.y) + 6)
            annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            annotation.endPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
            annotation.endLineStyle = .openArrow
        } else {
            let xs = points.map(\.x), ys = points.map(\.y)
            let bounds = CGRect(x: xs.min()! - 3, y: ys.min()! - 3, width: xs.max()! - xs.min()! + 6, height: ys.max()! - ys.min()! + 6)
            annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
            for p in points.dropFirst() { path.line(to: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
            annotation.add(path)
        }
        annotation.color = workspace.tool == .signature ? .black : NSColor(workspace.annotationColor)
        if workspace.tool == .signature { annotation.userName = "KongFolio Signature" }
        let border = PDFBorder()
        border.lineWidth = workspace.tool == .signature ? 1.6 : 2.0
        annotation.border = border
        page.addAnnotation(annotation)
        provisional = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
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
