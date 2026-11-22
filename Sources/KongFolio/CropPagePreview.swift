import SwiftUI
import PDFKit

enum CropPreviewGeometry {
    struct Target: Equatable {
        // −1 is the near edge, 1 the far edge, and 0 means the axis is unchanged.
        let horizontal: Int
        let vertical: Int
        static let move = Target(horizontal: 0, vertical: 0)
    }

    static func area(for margins: CropMargins, in size: CGSize) -> CGRect {
        let m = margins.clamped
        return CGRect(x: m.left * size.width, y: m.top * size.height,
                      width: (1 - m.left - m.right) * size.width,
                      height: (1 - m.top - m.bottom) * size.height)
    }

    static func target(at point: CGPoint, in area: CGRect, hitRadius: CGFloat = 11) -> Target? {
        guard area.insetBy(dx: -hitRadius, dy: -hitRadius).contains(point) else { return nil }
        func edge(_ value: CGFloat, near: CGFloat, far: CGFloat) -> Int {
            let nearest = abs(near - value)
            let farthest = abs(far - value)
            guard min(nearest, farthest) <= hitRadius else { return 0 }
            return nearest <= farthest ? -1 : 1
        }
        let horizontal = edge(point.x, near: area.minX, far: area.maxX)
        let vertical = edge(point.y, near: area.minY, far: area.maxY)
        return Target(horizontal: horizontal, vertical: vertical)
    }

    static func adjusted(_ start: CropMargins, target: Target, translation: CGSize, in size: CGSize) -> CropMargins {
        guard size.width > 0, size.height > 0 else { return start }
        let dx = Double(translation.width / size.width)
        let dy = Double(translation.height / size.height)
        var next = start.clamped
        let limit = CropMargins.limit
        if target == .move {
            let moveX = min(min(next.right, limit - next.left), max(dx, -next.left, next.right - limit))
            let moveY = min(min(next.bottom, limit - next.top), max(dy, -next.top, next.bottom - limit))
            next.left += moveX
            next.right -= moveX
            next.top += moveY
            next.bottom -= moveY
        } else {
            if target.horizontal == -1 { next.left += dx }
            if target.horizontal == 1 { next.right -= dx }
            if target.vertical == -1 { next.top += dy }
            if target.vertical == 1 { next.bottom -= dy }
        }
        return next.clamped
    }
}

struct CropPagePreview: View {
    let page: PDFPage
    let revision: UUID
    let editing: Bool
    @Binding var margins: CropMargins
    @State private var image: NSImage?
    @GestureState private var trackingDrag = false
    @State private var drag: Drag?

    private struct Drag {
        let start: CropMargins
        let target: CropPreviewGeometry.Target
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { cropBox }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: revision) {
            image = page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
        }
        .onChange(of: trackingDrag) { _, tracking in
            if !tracking { drag = nil }
        }
    }

    private var cropBox: some View {
        GeometryReader { proxy in
            let kept = CropPreviewGeometry.area(for: margins, in: proxy.size)
            let handles = [
                CGPoint(x: kept.minX, y: kept.minY), CGPoint(x: kept.midX, y: kept.minY),
                CGPoint(x: kept.maxX, y: kept.minY), CGPoint(x: kept.maxX, y: kept.midY),
                CGPoint(x: kept.maxX, y: kept.maxY), CGPoint(x: kept.midX, y: kept.maxY),
                CGPoint(x: kept.minX, y: kept.maxY), CGPoint(x: kept.minX, y: kept.midY)
            ]
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(kept)
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: kept.width, height: kept.height)
                    .position(x: kept.midX, y: kept.midY)
                if editing {
                    ForEach(handles.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                            .frame(width: 9, height: 9)
                            .position(handles[index])
                    }
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 3)
                    .updating($trackingDrag) { _, tracking, _ in tracking = true }
                    .onChanged { gesture in
                        if drag == nil, let target = CropPreviewGeometry.target(at: gesture.startLocation, in: kept) {
                            drag = Drag(start: margins, target: target)
                        }
                        guard let drag else { return }
                        margins = CropPreviewGeometry.adjusted(drag.start, target: drag.target,
                                                              translation: gesture.translation, in: proxy.size)
                    },
                including: editing ? .all : .none
            )
            .accessibilityHidden(true)
        }
    }
}
