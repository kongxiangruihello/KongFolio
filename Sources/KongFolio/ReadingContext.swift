import Foundation
import PDFKit
import AppKit
struct ReadingContextRequest:Identifiable { var id = UUID();var source:SourceRef }
struct ReadingContextImage { var png:Data;var title:String }
enum ReadingContextLoader {
    static func load(_ source:SourceRef,wholePage:Bool) throws -> ReadingContextImage {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath:source.path);let values = try url.resourceValues(forKeys:[.fileSizeKey,.ubiquitousItemDownloadingStatusKey])
        if let state = values.ubiquitousItemDownloadingStatus,state != .current { throw FolioError(message:"原文尚在云端，请先通过“返回原文”下载后再快看") }
        guard (values.fileSize ?? 0)<250_000_000 else { throw FolioError(message:"原文较大，请使用“返回原文”按需阅读") }
        guard let doc = PDFDocument(url:url),!doc.isLocked,source.page>=0,source.page<doc.pageCount,let page = doc.page(at:source.page) else { throw FolioError(message:"原文不存在、已加密或页码已变化") }
        try Task.checkCancellation()
        let thumbnail = page.thumbnail(of:NSSize(width:1100,height:1400),for:.cropBox)
        var rect = CGRect(origin:.zero,size:thumbnail.size)
        let box = page.bounds(for:.cropBox),union = source.rects.reduce(CGRect.null){$0.union($1)}
        if !wholePage,page.rotation == 0,!union.isNull,!union.isEmpty,box.width>0,box.height>0 {
            let context = union.insetBy(dx:-box.width*0.08,dy:-box.height*0.10).intersection(box)
            rect = CGRect(x:(context.minX-box.minX)/box.width*thumbnail.size.width,y:(context.minY-box.minY)/box.height*thumbnail.size.height,width:context.width/box.width*thumbnail.size.width,height:context.height/box.height*thumbnail.size.height)
        }
        guard let image = thumbnail.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw FolioError(message:"原页预览生成失败") }
        let sx = Double(image.width)/max(1,thumbnail.size.width),sy = Double(image.height)/max(1,thumbnail.size.height)
        let pixels = CGRect(x:rect.minX*sx,y:Double(image.height)-rect.maxY*sy,width:rect.width*sx,height:rect.height*sy).integral
        guard let cropped = image.cropping(to:pixels),let png = SignatureImage.pngData(cropped) else { throw FolioError(message:"原页预览生成失败") }
        try Task.checkCancellation()
        return ReadingContextImage(png:png,title:source.fileName+" · PDF 第 \(source.page+1) 页")
    }
}
