import AppKit

// KongFolio icon in the shared kong-series style: flat blue base (#3B73EF, as in KongFetch),
// white stacked pages for "folio", and a lowercase "k" on the front page.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let blue = NSColor(srgbRed: 59 / 255, green: 115 / 255, blue: 239 / 255, alpha: 1)

func drawIcon() {
    let backdrop = NSBezierPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205)
    blue.setFill()
    backdrop.fill()
    let pages: [(CGFloat, CGFloat, CGFloat)] = [(232, 236, 0.35), (268, 266, 0.6), (304, 296, 1)]
    for (x, y, alpha) in pages {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: 452, height: 560), xRadius: 44, yRadius: 44).fill()
    }
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let font = NSFont.systemFont(ofSize: 430, weight: .heavy)
    let glyph = NSAttributedString(string: "k", attributes: [.font: font, .foregroundColor: blue, .paragraphStyle: style])
    let size = glyph.size()
    glyph.draw(in: CGRect(x: 304 + (452 - size.width) / 2, y: 296 + (560 - size.height) / 2 + 12, width: size.width, height: size.height))
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
