import AppKit
import PDFKit
import CryptoKit

struct PageDifference: Identifiable, Equatable {
    var id: Int
    var before: Int?
    var after: Int?
    var changes: [String]
    var changed: Bool { !changes.isEmpty }
    var title: String {
        let left=before.map { "\($0+1)" } ?? "—",right=after.map { "\($0+1)" } ?? "—"
        return "\(left) → \(right) · " + (changes.isEmpty ? "相同" : changes.joined(separator:"、"))
    }
}

enum PDFComparison {
    struct Signature {
        var identity: String
        var visual: String
        var text: String
        var rotation: Int
        var crop: CGRect
        var annotations: String
    }
    static func signature(_ page: PDFPage) throws -> Signature {
        guard let reference=page.pageRef else { throw FolioError(message:"无法读取对照页面") }
        // Core Graphics draws the underlying media content without PDFKit annotation objects, crop or rotation.
        // Never remove annotations from PDFPage.copy(): some PDFKit versions share their backing array.
        var rawIdentity=Data(count:180*180*4)
        let media=page.bounds(for:.mediaBox)
        guard media.width>0,media.height>0 else { throw FolioError(message:"对照页面尺寸无效") }
        let identityDrawn=rawIdentity.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:180,height:180,bitsPerComponent:8,bytesPerRow:720,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:180,height:180))
            let scale=min(180/media.width,180/media.height)
            context.translateBy(x:(180-media.width*scale)/2,y:(180-media.height*scale)/2)
            context.scaleBy(x:scale,y:scale);context.translateBy(x:-media.minX,y:-media.minY)
            context.drawPDFPage(reference);return true
        }
        guard identityDrawn else { throw FolioError(message:"无法生成页面指纹") }
        func pixels(_ page: PDFPage) throws -> String {
            let image=try DocumentServices.render(page,maxDimension:180)
            var bytes=Data(count:180*180*4)
            let rendered=bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context=CGContext(data:raw.baseAddress,width:180,height:180,bitsPerComponent:8,bytesPerRow:720,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:180,height:180))
                context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
            }
            guard rendered else { throw FolioError(message:"无法生成对照图像") }
            return OCRPageCache.digest(bytes)
        }
        let annotations=page.annotations.map { a in
            [a.type ?? "",a.contents ?? "",NSStringFromRect(a.bounds),a.color.description,a.interiorColor?.description ?? "",a.font?.fontName ?? "",String(Double(a.font?.pointSize ?? 0))].joined(separator:"|")
        }.sorted().joined(separator:"\n")
        return Signature(identity:OCRPageCache.digest(rawIdentity),visual:try pixels(page),text:page.string ?? "",rotation:(page.rotation%360+360)%360,crop:page.bounds(for:.cropBox),annotations:annotations)
    }
    /// Unique occurrence keys and a longest increasing sequence align unchanged pages in O(n log n).
    /// A moved page is reported as a removal and addition. Unmatched gaps are compared in order.
    static func align(_ before: [String], _ after: [String]) -> [(Int?,Int?)] {
        func keys(_ values:[String]) -> [String] {
            var counts:[String:Int]=[:]
            return values.map { value in let n=counts[value,default:0];counts[value]=n+1;return value+"#\(n)" }
        }
        let left=keys(before),right=keys(after)
        let positions=Dictionary(uniqueKeysWithValues:left.enumerated().map { ($0.element,$0.offset) })
        let candidates=right.enumerated().compactMap { offset,key in positions[key].map { (old:$0,new:offset) } }
        var tails:[Int]=[],links=Array(repeating:-1,count:candidates.count)
        for i in candidates.indices {
            var low=0,high=tails.count
            while low<high { let mid=(low+high)/2;if candidates[tails[mid]].old<candidates[i].old { low=mid+1 } else { high=mid } }
            if low>0 { links[i]=tails[low-1] }
            if low==tails.count { tails.append(i) } else { tails[low]=i }
        }
        var anchors:[(Int,Int)]=[],last=tails.last ?? -1
        while last>=0 { anchors.append((candidates[last].old,candidates[last].new));last=links[last] }
        anchors.reverse();anchors.append((before.count,after.count))
        var result:[(Int?,Int?)]=[],a=0,b=0
        for (x,y) in anchors {
            while a<x || b<y { result.append((a<x ? a : nil,b<y ? b : nil));if a<x { a+=1 };if b<y { b+=1 } }
            if x<before.count { result.append((x,y));a=x+1;b=y+1 }
        }
        return result
    }
    static func compare(_ before: Data, _ after: Data, progress: (Double)->Void = { _ in }) throws -> [PageDifference] {
        guard let left=PDFDocument(data:before),let right=PDFDocument(data:after),!left.isLocked,!right.isLocked else { throw FolioError(message:"无法读取比较版本") }
        var a:[Signature]=[],b:[Signature]=[]
        let total=max(1,left.pageCount+right.pageCount)
        for (doc,isLeft) in [(left,true),(right,false)] {
            for index in 0..<doc.pageCount {
                try Task.checkCancellation()
                let value=try autoreleasepool { try signature(doc.page(at:index).unwrap("比较页面缺失")) }
                if isLeft { a.append(value) } else { b.append(value) }
                progress(Double(a.count+b.count)/Double(total))
            }
        }
        return align(a.map(\.identity),b.map(\.identity)).enumerated().map { number,pair in
            let (old,new)=pair
            guard let old,let new else { return PageDifference(id:number,before:old,after:new,changes:[old == nil ? "新增页" : "删除页"]) }
            let x=a[old],y=b[new]
            var changes:[String]=[]
            if x.rotation != y.rotation { changes.append("旋转") }
            if x.crop != y.crop { changes.append("裁边 / 尺寸") }
            if x.text != y.text { changes.append("文字") }
            if x.annotations != y.annotations { changes.append("批注") }
            if x.visual != y.visual && changes.isEmpty { changes.append("页面外观") }
            return PageDifference(id:number,before:old,after:new,changes:changes)
        }
    }
}

extension Workspace {
    /// Replace one existing page, retaining document-level structure and the selected version's page metadata.
    @discardableResult func restoreHistoryPage(_ entry: HistoryEntry, page oldIndex: Int, replacing index: Int) -> Bool {
        guard !busy,let source=historySource,(0..<count).contains(index) else { return false }
        do {
            let archive=try DocumentHistory.read(entry,source:source,storage:storage)
            let original=PDFDocument(data:archive.pdf)
            guard let page=original?.page(at:oldIndex)?.copy() as? PDFPage else { throw FolioError(message:"历史页面不存在") }
            try DocumentHistory.record(snapshot(),source:source,storage:storage,label:"恢复单页前的当前工作",automatic:false)
            checkpoint()
            document.removePage(at:index);document.insert(page,at:index)
            alignMeta()
            pageMeta[index]=PageMeta(ocrOriginal:archive.ocrOriginals?[oldIndex],ocrRegions:archive.ocrRegions?[oldIndex])
            ReadingServices.applyOutline(outlineEntries,to:document)
            selection=index;selectedPages=[index];readingPoint=nil;navigationToken=UUID();edited(reset:true)
            return saveDirectly(askForDestination:false)
        } catch { self.error="无法恢复历史页面：\(error.localizedDescription)";return false }
    }
}
