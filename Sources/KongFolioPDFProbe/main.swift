import Foundation
import PDFKit
import CryptoKit
import AppKit

// PDFKit's first parse and optional source-image rendering run outside the reader.
struct Result:Codable { var pages:Int;var digest:String }
struct Region:Codable { var page:Int;var rects:[CGRect];var fingerprint:String? = nil }
func document(_ source:String)throws->(Data,PDFDocument) {
    let data=try Data(contentsOf:URL(fileURLWithPath:source),options:.mappedIfSafe)
    guard let doc=PDFDocument(data:data) else { throw NSError(domain:"PDFProbe",code:1) }
    if doc.isLocked { exit(67) }
    guard doc.pageCount>0 else { throw NSError(domain:"PDFProbe",code:1) }
    return (data,doc)
}
do {
    let args=CommandLine.arguments
    if args.count==5,args[1]=="--region" {
        let (bytes,doc)=try document(args[2])
        guard let requestData=Data(base64Encoded:args[4]) else { exit(64) }
        let region=try JSONDecoder().decode(Region.self,from:requestData)
        if let expected=region.fingerprint,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() != expected { exit(66) }
        guard let page=doc.page(at:region.page) else { exit(65) }
        let pageBox=page.bounds(for:.cropBox)
        let union=region.rects.reduce(CGRect.null){$0.union($1)}
        let crop=union.isNull ? pageBox:union.insetBy(dx:-12,dy:-12).intersection(pageBox)
        guard !crop.isNull,crop.width>0,crop.height>0,[crop.minX,crop.minY,crop.width,crop.height].allSatisfy({$0.isFinite}) else { exit(65) }
        let scale=min(2,1000/max(crop.width,crop.height))
        let w=max(1,Int(ceil(crop.width*scale))),h=max(1,Int(ceil(crop.height*scale)))
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let graphics=NSGraphicsContext(bitmapImageRep:bitmap) else { exit(65) }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
        let c=graphics.cgContext;c.setFillColor(NSColor.white.cgColor);c.fill(CGRect(x:0,y:0,width:w,height:h));c.scaleBy(x:scale,y:scale);c.translateBy(x:-crop.minX,y:-crop.minY)
        page.draw(with:.cropBox,to:c)
        NSGraphicsContext.restoreGraphicsState()
        guard let png=bitmap.representation(using:.png,properties:[:]) else { exit(65) }
        try png.write(to:URL(fileURLWithPath:args[3]),options:.atomic)
    } else {
        guard args.count==3 else { exit(64) }
        let (data,doc)=try document(args[1])
        for i in 0..<doc.pageCount {
            try autoreleasepool {
                guard let page=doc.page(at:i) else { throw NSError(domain:"PDFProbe",code:1) }
                let b=page.bounds(for:.mediaBox)
                guard [b.minX,b.minY,b.width,b.height].allSatisfy({$0.isFinite}),b.width>0,b.height>0,b.width<100000,b.height<100000 else { throw NSError(domain:"PDFProbe",code:2) }
                _=page.string
            }
        }
        let result=Result(pages:doc.pageCount,digest:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined())
        try JSONEncoder().encode(result).write(to:URL(fileURLWithPath:args[2]),options:.atomic)
    }
} catch { exit(65) }
