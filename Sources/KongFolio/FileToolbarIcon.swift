import SwiftUI

extension FileToolbarAction {
    var icon: Image {
        if self == .library { return Image(nsImage: LibraryBriefcase.image).renderingMode(.template) }
        return Image(systemName: symbol)
    }

    @ViewBuilder func label(_ title: String) -> some View {
        if self == .library {
            Label { Text(title) } icon: { icon }
        } else {
            Label(title, systemImage: symbol)
        }
    }
}

private enum LibraryBriefcase {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
            let outline = NSBezierPath()
            outline.appendRoundedRect(NSRect(x: 1.25, y: 2.5, width: 16.5, height: 11.5), xRadius: 1.75, yRadius: 1.75)

            outline.move(to: NSPoint(x: 6.7, y: 14))
            outline.line(to: NSPoint(x: 6.7, y: 16.6))
            outline.line(to: NSPoint(x: 12.3, y: 16.6))
            outline.line(to: NSPoint(x: 12.3, y: 14))

            outline.appendRoundedRect(NSRect(x: 4.5, y: 7.7, width: 2.5, height: 2.6), xRadius: 0.55, yRadius: 0.55)
            outline.appendRoundedRect(NSRect(x: 12, y: 7.7, width: 2.5, height: 2.6), xRadius: 0.55, yRadius: 0.55)
            let seam: [ClosedRange<CGFloat>] = [1.25...4.5, 7...12, 14.5...17.75]
            for segment in seam {
                outline.move(to: NSPoint(x: segment.lowerBound, y: 9))
                outline.line(to: NSPoint(x: segment.upperBound, y: 9))
            }

            NSColor.black.setStroke()
            outline.lineWidth = 1.15
            outline.lineJoinStyle = .round
            outline.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
