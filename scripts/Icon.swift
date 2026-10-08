import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
 for scale in [1, 2] {
  let pixels = size * scale
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let ctx = NSGraphicsContext.current!.cgContext; ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
  let backdrop = NSBezierPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205)
  NSGradient(starting: NSColor(calibratedRed: 0.03, green: 0.56, blue: 0.53, alpha: 1), ending: NSColor(calibratedRed: 0.03, green: 0.25, blue: 0.30, alpha: 1))!.draw(in: backdrop, angle: -65)
  NSColor.white.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: CGRect(x: 236, y: 207, width: 450, height: 565), xRadius: 42, yRadius: 42).fill()
  NSColor.white.withAlphaComponent(0.50).setFill(); NSBezierPath(roundedRect: CGRect(x: 274, y: 237, width: 450, height: 565), xRadius: 42, yRadius: 42).fill()
  NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: 312, y: 267, width: 450, height: 565), xRadius: 42, yRadius: 42).fill()
  NSColor(calibratedRed: 0.06, green: 0.43, blue: 0.44, alpha: 1).setFill()
  NSBezierPath(roundedRect: CGRect(x: 405, y: 365, width: 58, height: 355), xRadius: 12, yRadius: 12).fill()
  NSBezierPath(roundedRect: CGRect(x: 405, y: 662, width: 252, height: 58), xRadius: 12, yRadius: 12).fill()
  NSBezierPath(roundedRect: CGRect(x: 405, y: 524, width: 205, height: 58), xRadius: 12, yRadius: 12).fill()
  NSGraphicsContext.restoreGraphicsState()
  let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
  try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
 }
}
