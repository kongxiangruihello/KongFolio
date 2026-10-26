import AppKit
import PDFKit

enum RecipeTrial {
    struct Result { var before:Data;var after:Data;var rows:[PageDifference];var message:String }
    static func run(source:URL,range:String,recipe:WorkRecipe,replacements:[ReplacementRule]) throws -> Result {
        let original=try DocumentServices.load(source)
        guard let pages=PageSpan.parse(range,pageCount:original.pageCount),!pages.isEmpty,pages.count<=6 else { throw FolioError(message:"试跑请选择 1–6 页，例如 1-3 或 10,20,30。") }
        try Task.checkCancellation()
        let data=try DocumentServices.subset(original,indexes:pages).dataRepresentation().unwrap("无法读取试跑页")
        var test=recipe;test.pageRange="";test.word=nil;test.splitChapters=false;test.writePDF=true
        let result=try BatchPipeline.process(data,recipe:test,replacements:replacements,wordURL:nil)
        let output=try result.pdf.unwrap("试跑结果为空")
        var rows:[PageDifference]
        if test.splitSpreads {
            rows=(0..<result.pages).map { PageDifference(id:$0,before:$0/2,after:$0,changes:["切分 · 原件第 \(pages[$0/2]+1) 页"]) }
        } else { rows=try PDFComparison.compare(data,output) }
        for index in rows.indices {
            if let target=rows[index].after,let angle=result.angles[target] { rows[index].changes.append(String(format:"纠偏 %.2f°",angle)) }
        }
        // Guides belong only to the disposable preview copy, never the input or exported result.
        let preview=try PDFDocument(data:data).unwrap("无法读取试跑预览")
        if test.splitSpreads || (test.autoCrop && !test.autoStraighten) {
            for index in 0..<result.pages {
                let old=test.splitSpreads ? index/2 : index
                guard let page=preview.page(at:old) else { continue }
                let box:CGRect?
                if test.splitSpreads {
                    // With straightening, subsequent crop coordinates are in a new page space; draw the split only.
                    if !test.autoStraighten,let crop=result.cropGuides[index] { box=crop }
                    else { let halves=ScanProcessing.splitBoxes(page,fraction:test.splitFraction);box=halves[test.rightPageFirst ? 1-index%2 : index%2] }
                } else { box=result.cropGuides[index] }
                if let box {
                    let guide=PDFAnnotation(bounds:box,forType:.square,withProperties:nil);guide.color = .systemBlue
                    let border=PDFBorder();border.lineWidth=1.5;guide.border=border;page.addAnnotation(guide)
                }
            }
        }
        let message="试跑 \(pages.count) 页 → \(result.pages) 页 · PDF 数据 \(ByteCountFormatter.string(fromByteCount:Int64(data.count),countStyle:.file)) → \(ByteCountFormatter.string(fromByteCount:Int64(output.count),countStyle:.file))。蓝框为切分 / 裁边范围；纠偏后的裁边请在右侧检查。"
        return Result(before:try preview.dataRepresentation().unwrap("无法显示试跑预览"),after:output,rows:rows,message:message)
    }
}
