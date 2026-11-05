import AppKit
import PDFKit

enum ReadingVisual053 {
    static func annotation(_ annotation:PDFAnnotation)->Data? {
        let b=annotation.bounds.insetBy(dx:-8,dy:-8)
        guard [b.width,b.height,b.minX,b.minY].allSatisfy({$0.isFinite}),b.width>0,b.height>0 else { return nil }
        let scale=min(2,800/max(b.width,b.height))
        let w=max(1,Int(ceil(b.width*scale))),h=max(1,Int(ceil(b.height*scale)))
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let graphics=NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current=graphics
        let c=graphics.cgContext;c.setFillColor(NSColor.white.cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h));c.scaleBy(x:scale,y:scale);c.translateBy(x:-b.minX,y:-b.minY)
        annotation.draw(with:.cropBox,in:c)
        return bitmap.representation(using:.png,properties:[:])
    }
    static func store(_ data:Data,folder:URL)throws->String {
        let name=OCRPageCache.digest(data)+".png",directory=folder.appendingPathComponent("Assets"),file=directory.appendingPathComponent(name)
        try ReadingBackupStorage.checked(directory);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:file.path) { guard try Data(contentsOf:file)==data else { throw FolioError(message:"已有图片校验不符") } }
        else { try data.write(to:file,options:.atomic) }
        return name
    }
}
