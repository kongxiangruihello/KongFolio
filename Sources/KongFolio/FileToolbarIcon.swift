import SwiftUI

extension FileToolbarAction {
    @ViewBuilder var icon: some View {
        if self == .library || self == .pageThumbnails {
            CustomFileToolbarIcon(action: self)
        } else {
            AppIcon(symbol)
        }
    }

    @ViewBuilder func label(_ title: String) -> some View {
        if self == .library || self == .pageThumbnails {
            Label { Text(title) } icon: { icon }
        } else {
            Label(title, appIcon: symbol)
        }
    }
}

private struct CustomFileToolbarIcon: View {
    let action: FileToolbarAction
    @Environment(\.toolbarIconTone) private var tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if action == .library {
            Image(nsImage: LibraryBriefcase.image)
                .renderingMode(tone == nil ? .original : .template)
                .foregroundStyle(tone ?? .primary)
        } else {
            let image = tone == nil ? PDFPageExtractionIcon.image :
                (scheme == .dark ? PDFPageExtractionIcon.lightGraphite : PDFPageExtractionIcon.darkGraphite)
            Image(nsImage: image).renderingMode(.original)
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

            NSColor.systemIndigo.setStroke()
            outline.lineWidth = 1.15
            outline.lineJoinStyle = .round
            outline.stroke()
            return true
        }
        return image
    }()
}

private enum PDFPageExtractionIcon {
    static let image = makeImage(
        outline: NSColor(srgbRed: 0.25, green: 0.51, blue: 0.74, alpha: 1),
        accent: NSColor(srgbRed: 0.07, green: 0.42, blue: 0.82, alpha: 1),
        paper: NSColor(srgbRed: 0.91, green: 0.96, blue: 1, alpha: 1),
        badgeFill: NSColor(srgbRed: 0.83, green: 0.20, blue: 0.20, alpha: 1)
    )
    static let darkGraphite = graphite(inDarkMode: false)
    static let lightGraphite = graphite(inDarkMode: true)

    private static func graphite(inDarkMode: Bool) -> NSImage {
        let ink = PDFToolbarPalette.graphiteColor(inDarkMode: inDarkMode)
        let paper = inDarkMode ? NSColor(white: 0.16, alpha: 1) : .white
        return makeImage(outline: ink, accent: ink, paper: paper, badgeFill: ink, badgeText: paper)
    }

    private static func makeImage(outline: NSColor, accent: NSColor, paper: NSColor,
                                  badgeFill: NSColor, badgeText: NSColor = .white) -> NSImage {
        NSImage(size: NSSize(width: 25, height: 25), flipped: true) { _ in
            func path(_ points: [NSPoint], closed: Bool = false) -> NSBezierPath {
                let shape = NSBezierPath()
                shape.move(to: points[0])
                for point in points.dropFirst() { shape.line(to: point) }
                if closed { shape.close() }
                shape.lineJoinStyle = .round
                shape.lineCapStyle = .round
                return shape
            }

            let page = path([NSPoint(x: 3, y: 3.5), NSPoint(x: 15.5, y: 3.5), NSPoint(x: 19.5, y: 7.5),
                             NSPoint(x: 19.5, y: 22.5), NSPoint(x: 3, y: 22.5)], closed: true)
            paper.setFill()
            page.fill()
            outline.setStroke()
            page.lineWidth = 1.3
            page.stroke()

            let fold = path([NSPoint(x: 15.5, y: 3.8), NSPoint(x: 15.5, y: 7.5), NSPoint(x: 19.2, y: 7.5)])
            fold.lineWidth = 0.9
            fold.stroke()

            let lines = NSBezierPath()
            lines.lineCapStyle = .round
            lines.lineWidth = 1.1
            for y in [12.0, 14.5, 19.6] {
                lines.move(to: NSPoint(x: 5.5, y: y))
                lines.line(to: NSPoint(x: 15.9, y: y))
            }
            lines.stroke()

            let cut = NSBezierPath()
            cut.move(to: NSPoint(x: 1.9, y: 17))
            cut.line(to: NSPoint(x: 17.3, y: 17))
            cut.lineWidth = 1
            cut.setLineDash([1.3, 1.3], count: 2, phase: 0)
            cut.stroke()

            let scissors = path([NSPoint(x: 13.5, y: 15.6), NSPoint(x: 20.6, y: 21.3)])
            scissors.move(to: NSPoint(x: 14.2, y: 20.7))
            scissors.line(to: NSPoint(x: 21.1, y: 18.6))
            accent.setStroke()
            scissors.lineWidth = 1.15
            scissors.stroke()
            for y in [17.5, 20.9] {
                let ring = NSBezierPath(ovalIn: NSRect(x: 20.4, y: y, width: 2.8, height: 2.8))
                paper.setFill()
                ring.fill()
                ring.lineWidth = 1.1
                ring.stroke()
            }

            let badge = NSBezierPath(roundedRect: NSRect(x: 1.1, y: 6, width: 9.7, height: 5.1),
                                     xRadius: 1.15, yRadius: 1.15)
            badgeFill.setFill()
            badge.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 3.9, weight: .bold), .foregroundColor: badgeText
            ]
            let mark = "PDF" as NSString
            let size = mark.size(withAttributes: attributes)
            mark.draw(at: NSPoint(x: 5.95 - size.width / 2, y: 8.55 - size.height / 2), withAttributes: attributes)
            return true
        }
    }
}
