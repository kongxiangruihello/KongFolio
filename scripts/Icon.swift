import AppKit

// Rounded square silhouette, with a single high-contrast folio for small Dock sizes.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let blue = NSColor(srgbRed: 59 / 255, green: 115 / 255, blue: 239 / 255, alpha: 1)

func drawIcon() {
    NSGraphicsContext.current?.imageInterpolation = .high
    let backdrop = NSBezierPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208)
    blue.setFill();backdrop.fill()
    let inset=NSBezierPath(roundedRect:CGRect(x:68,y:68,width:888,height:888),xRadius:190,yRadius:190)
    NSColor.white.withAlphaComponent(0.18).setStroke();inset.lineWidth=5;inset.stroke()
    NSColor.white.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect:CGRect(x:232,y:217,width:452,height:560),xRadius:44,yRadius:44).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect:CGRect(x:304,y:296,width:452,height:560),xRadius:44,yRadius:44).fill()
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
