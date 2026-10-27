import SwiftUI
import AppKit

/// Bound panels to the parent window and usable display. Oversized controls remain reachable by scrolling.
enum SheetMetrics {
    static func size(preferred: CGSize, parent: CGSize?, screen: CGSize) -> CGSize {
        CGSize(width: max(280, min(preferred.width, (parent?.width ?? screen.width) - 24, screen.width - 48)),
               height: max(200, min(preferred.height, (parent?.height ?? screen.height) - 48, screen.height - 100)))
    }
}
private struct AdaptiveSheet: ViewModifier {
    var preferred: CGSize
    var minimumWidth: CGFloat
    @State private var parent: CGSize?
    func body(content: Content) -> some View {
        let screen = NSApp.keyWindow?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let size = SheetMetrics.size(preferred: preferred, parent: parent ?? NSApp.keyWindow?.sheetParent?.contentView?.bounds.size ?? NSApp.keyWindow?.contentView?.bounds.size, screen: screen)
        return ScrollView([.horizontal, .vertical]) {
            content.frame(width: max(size.width, minimumWidth), height: preferred.height)
        }
        .frame(width: size.width, height: size.height)
        .background(PanelParentObserver { parent = $0 })
    }
}
private struct PanelParentObserver: NSViewRepresentable {
    var update: (CGSize) -> Void
    func makeNSView(context: Context) -> Observer { let view = Observer(); view.update = update; return view }
    func updateNSView(_ view: Observer, context: Context) { view.update = update; view.report() }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.tokens.forEach(NotificationCenter.default.removeObserver) }
    final class Observer: NSView {
        var update: ((CGSize) -> Void)?
        var tokens: [NSObjectProtocol] = []
        var last: CGSize?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            // A sheet acquires sheetParent after viewDidMoveToWindow; listen to its first update as well as parent resizing.
            for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.report() })
            }
            report()
        }
        func report() {
            guard let size = window?.sheetParent?.contentView?.bounds.size, size != last else { return }
            last = size
            DispatchQueue.main.async { [weak self] in self?.update?(size) }
        }
    }
}
extension View {
    func adaptiveSheet(width: CGFloat, height: CGFloat = 600, minimumWidth: CGFloat? = nil) -> some View { modifier(AdaptiveSheet(preferred: CGSize(width: width, height: height), minimumWidth: minimumWidth ?? width)) }
}

/// Rows wrap instead of dropping their trailing actions outside the available panel width.
struct PanelRow: Layout {
    var spacing: CGFloat = 8
    private func layout(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGSize, [(CGPoint, CGSize)]) {
        let width = max(1, proposal.width ?? 800)
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, positions: [(CGPoint, CGSize)] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            size.width = min(width, size.width)
            if x > 0, x + size.width > width { x = 0; y += height + spacing; height = 0 }
            positions.append((CGPoint(x: x, y: y), size)); x += size.width + spacing; height = max(height, size.height)
        }
        return (CGSize(width: width, height: y + height), positions)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { layout(proposal, subviews).0 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = layout(ProposedViewSize(width: bounds.width, height: nil), subviews).1
        for (i, pair) in positions.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + pair.0.x, y: bounds.minY + pair.0.y), anchor: .topLeading, proposal: ProposedViewSize(pair.1)) }
    }
}
