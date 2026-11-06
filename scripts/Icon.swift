import AppKit

// Rounded square silhouette, with a single high-contrast folio for small Dock sizes.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let blue = NSColor(srgbRed: 23 / 255, green: 58 / 255, blue: 98 / 255, alpha: 1)

func drawIcon() {
    NSGraphicsContext.current?.imageInterpolation = .high
    let backdrop = NSBezierPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208)
    NSGradient(starting:blue,ending:NSColor(srgbRed:14/255,green:37/255,blue:68/255,alpha:1))!.draw(in:backdrop,angle:-90)
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.23);shadow.shadowBlurRadius=28;shadow.shadowOffset=NSSize(width:0,height:-15);shadow.set()
    NSColor(srgbRed:0.85,green:0.83,blue:0.76,alpha:1).setFill()
    NSBezierPath(roundedRect:CGRect(x:244,y:194,width:492,height:626),xRadius:38,yRadius:38).fill()
    NSGraphicsContext.restoreGraphicsState()
    let paper=NSBezierPath(roundedRect:CGRect(x:272,y:214,width:492,height:626),xRadius:38,yRadius:38)
    NSGradient(starting:NSColor(srgbRed:1,green:0.985,blue:0.945,alpha:1),ending:NSColor(srgbRed:0.94,green:0.925,blue:0.875,alpha:1))!.draw(in:paper,angle:-90)
    blue.withAlphaComponent(0.28).setStroke()
    for (y,length) in [(526.0,208.0),(450.0,300.0),(374.0,234.0)] {
        let line=NSBezierPath();line.lineWidth=22;line.lineCapStyle = .round
        line.move(to:CGPoint(x:350,y:y));line.line(to:CGPoint(x:350+length,y:y));line.stroke()
    }
    let bookmark=NSBezierPath();bookmark.move(to:CGPoint(x:606,y:840));bookmark.line(to:CGPoint(x:710,y:840));bookmark.line(to:CGPoint(x:710,y:600));bookmark.line(to:CGPoint(x:658,y:637));bookmark.line(to:CGPoint(x:606,y:600));bookmark.close()
    NSGradient(starting:NSColor(srgbRed:1,green:0.66,blue:0.30,alpha:1),ending:NSColor(srgbRed:0.89,green:0.43,blue:0.15,alpha:1))!.draw(in:bookmark,angle:-90)
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
