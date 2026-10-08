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
        let display: PDFDisplayMode = workspace.readingLayout == "单页" ? .singlePage : workspace.readingLayout == "双页" ? .twoUp : .singlePageContinuous
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
    private var moveStart = CGPoint.zero
    private var originalOrigin = CGPoint.zero
    private var didMove = false
    override func mouseDown(with event: NSEvent) {
        guard let workspace, !workspace.busy else { super.mouseDown(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        if workspace.tool == "选择" {
            // Route editable annotations through our tracked editor so edits are recoverable.
            if let hit = page.annotations.reversed().first(where: { ["FreeText", "Text"].contains($0.type ?? "") && $0.bounds.contains(point) }) {
                workspace.selectAnnotation(hit); workspace.tool = "编辑标注"; return
            }
            super.mouseDown(with: event); return
        }
        if workspace.tool == "编辑标注" {
            let hit = page.annotations.reversed().first { $0.type != "Link" && $0.type != "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
            workspace.selectAnnotation(hit); moving = hit; drawingPage = page; moveStart = point; originalOrigin = hit?.bounds.origin ?? .zero; didMove = false
            return
        }
        workspace.checkpoint(); drawingPage = page; points = [point]
        if workspace.tool == "文字框" || workspace.tool == "批注" {
            let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 40, width: workspace.tool == "批注" ? 28 : 220, height: workspace.tool == "批注" ? 28 : 50), forType: workspace.tool == "批注" ? .text : .freeText, withProperties: nil)
            annotation.contents = workspace.note.isEmpty ? "双击批注查看；右侧输入文字后可继续添加" : workspace.note
            annotation.font = NSFont(name: "Helvetica", size: 14); annotation.fontColor = .black; annotation.color = workspace.tool == "批注" ? .systemYellow : .clear
            page.addAnnotation(annotation); workspace.edited(); needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if let moving, let page = drawingPage, let workspace {
            if !didMove { workspace.checkpoint(); didMove = true }
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            moving.bounds.origin = CGPoint(x: originalOrigin.x + point.x - moveStart.x, y: originalOrigin.y + point.y - moveStart.y)
            needsDisplay = true; return
        }
        guard let workspace, ["画笔", "签名", "箭头"].contains(workspace.tool), let page = drawingPage else { super.mouseDragged(with: event); return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        points.append(point)
        if let provisional { page.removeAnnotation(provisional) }
        let annotation: PDFAnnotation
        if workspace.tool == "箭头", let start = points.first {
            let bounds = CGRect(x: min(start.x, point.x) - 3, y: min(start.y, point.y) - 3, width: abs(point.x - start.x) + 6, height: abs(point.y - start.y) + 6)
            annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY); annotation.endPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY); annotation.endLineStyle = .openArrow
        } else {
            let xs = points.map(\.x), ys = points.map(\.y)
            let bounds = CGRect(x: xs.min()! - 3, y: ys.min()! - 3, width: xs.max()! - xs.min()! + 6, height: ys.max()! - ys.min()! + 6)
            annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let path = NSBezierPath(); path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
            for p in points.dropFirst() { path.line(to: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
            annotation.add(path)
        }
        annotation.color = workspace.tool == "签名" ? .black : NSColor(workspace.annotationColor)
        if workspace.tool == "签名" { annotation.userName = "KongFolio Signature" }
        let border = PDFBorder(); border.lineWidth = workspace.tool == "签名" ? 1.6 : 2.0; annotation.border = border
        page.addAnnotation(annotation); provisional = annotation; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if moving != nil { if didMove { workspace?.edited() }; moving = nil; drawingPage = nil; didMove = false; return }
        if drawingPage != nil { provisional = nil; points = []; drawingPage = nil; workspace?.edited(); needsDisplay = true }
        else { super.mouseUp(with: event) }
    }
}
struct ComparisonCanvas: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = document; return view }
    func updateNSView(_ nsView: PDFView, context: Context) { if nsView.document !== document { nsView.document = document } }
}
