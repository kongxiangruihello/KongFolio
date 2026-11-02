import AppKit

struct EditorImage:Identifiable {
    var id:Int { range.location };var range:NSRange;var reference:String;var originalReference:String? = nil;var caption:String = ""
    static func list(_ text:String,format:TextDocumentFormat)->[Self] {
        let pattern = format == .html ? #"(?is)<img\b[^>]*>"# : #"!\[[^\]]*\]\((?:<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)"#
        guard format != .plain,let regex = try? NSRegularExpression(pattern:pattern) else { return [] };let ns = text as NSString
        return regex.matches(in:text,range:NSRange(location:0,length:ns.length)).compactMap { hit in
            guard let ref = TextAssets.references(ns.substring(with:hit.range),format:format).first else { return nil }
            var range = hit.range;var retained:String?
            let start = ns.range(of:"<!--kongfolio-image:start-->",options:.backwards,range:NSRange(location:0,length:hit.range.location))
            if start.location != NSNotFound {
                let end = ns.range(of:"<!--kongfolio-image:end-->",range:NSRange(location:NSMaxRange(hit.range),length:ns.length-NSMaxRange(hit.range)))
                let previousEnd = ns.range(of:"<!--kongfolio-image:end-->",options:.backwards,range:NSRange(location:0,length:hit.range.location))
                if end.location != NSNotFound,(previousEnd.location == NSNotFound || previousEnd.location < start.location) {
                    range = NSRange(location:start.location,length:NSMaxRange(end)-start.location)
                    let contents = ns.substring(with:range)
                    let regex = try! NSRegularExpression(pattern:#"<!--kongfolio-original-image:([^>]+)-->"#)
                    if let m = regex.firstMatch(in:contents,range:NSRange(location:0,length:contents.utf16.count)) { retained = (contents as NSString).substring(with:m.range(at:1)) }
                }
            }
            let tag = ns.substring(with:hit.range),alt = try! NSRegularExpression(pattern:format == .markdown ? #"!\[([^\]]*)\]"# : #"(?i)\balt="([^"]*)""#)
            let m = alt.firstMatch(in:tag,range:NSRange(location:0,length:tag.utf16.count)),caption = m.map { TextTableEntities.decode((tag as NSString).substring(with:$0.range(at:1))) } ?? ""
            return Self(range:range,reference:ref.reference,originalReference:retained,caption:caption)
        }
    }
}
struct EditorImageTransform {
    var x:Double = 0,y:Double = 0,width:Double = 1,height:Double = 1,outputWidth:Int = 350
    func png(_ data:Data) throws -> Data {
        guard [x,y,width,height].allSatisfy(\.isFinite),x >= 0,y >= 0,width > 0,height > 0,x+width <= 1.00001,y+height <= 1.00001,(16...2000).contains(outputWidth),let original = SignatureImage.loadData(data) else { throw FolioError(message:"裁剪区域应在图片内，输出宽度应为 16～2000") }
        let rect = CGRect(x:x*Double(original.width),y:y*Double(original.height),width:width*Double(original.width),height:height*Double(original.height)).integral
        guard let cropped = original.cropping(to:rect) else { throw FolioError(message:"无法裁剪这张图片") }
        let outputHeight = max(1,Int(Double(outputWidth)*Double(cropped.height)/Double(cropped.width)))
        guard outputHeight <= 10000,let context = CGContext(data:nil,width:outputWidth,height:outputHeight,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FolioError(message:"图片尺寸过大，请缩小输出宽度") }
        context.interpolationQuality = .high;context.draw(cropped,in:CGRect(x:0,y:0,width:outputWidth,height:outputHeight))
        guard let image = context.makeImage(),let png = SignatureImage.pngData(image) else { throw FolioError(message:"图片处理失败") };return png
    }
}
extension MarkdownNote {
    func editImage(_ image:EditorImage,source:String,data:Data,transform:EditorImageTransform,caption:String) throws {
        guard !readOnly,text == source,textView?.string == source,textView?.hasMarkedText() != true else { throw FolioError(message:"正文已变化，请重新打开图片编辑") }
        let result = try transform.png(data),folder = storage.appendingPathComponent("NoteAssets/"+id.uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let original = try TextMedia.read(image.originalReference ?? image.reference,baseURL:fileURL?.deletingLastPathComponent() ?? recoveryBaseURL)
        let retained = folder.appendingPathComponent("original-"+SignaturePersistence.digest(original).prefix(16)+".png")
        if !FileManager.default.fileExists(atPath:retained.path) { try original.write(to:retained,options:.atomic) }
        let file = folder.appendingPathComponent(UUID().uuidString+".png");try result.write(to:file,options:.atomic)
        let c = caption.replacingOccurrences(of:"\n",with:" "),markup = format == .html ? "<img src=\"\(file.absoluteString)\" alt=\"\(TextTableEntities.escape(c))\">"+(c.isEmpty ? "" : "<p>"+TextTableEntities.escape(c)+"</p>") : "!["+c.replacingOccurrences(of:"]",with:"\\]")+"](\(file.absoluteString))"+(c.isEmpty ? "" : "\n\n"+c)
        let value = "<!--kongfolio-image:start-->\n"+markup+"\n<!--kongfolio-original-image:"+retained.absoluteString+"-->\n<!--kongfolio-image:end-->"
        _ = commitEditorEdit(TextEdit(range:image.range,replacement:value,selection:NSRange(location:image.range.location,length:value.utf16.count)),expected:source)
    }
}
