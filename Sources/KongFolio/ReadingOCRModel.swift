import Foundation
import CoreGraphics

struct ReadingOCRSegment:Codable,Identifiable,Equatable {
    var id = UUID()
    var text:String
    var original:String
    var box:CGRect
}
enum ReadingOCROrder:String,CaseIterable { case rightToLeft = "竖排：右列到左列",leftToRight = "竖排：左列到右列",horizontal = "横排：从上到下" }
enum ReadingOCRSegments {
    static func make(_ lines:[RecognizedLine],vertical:Bool) -> [ReadingOCRSegment] {
        var groups:[[RecognizedLine]] = []
        for line in lines {
            let center = vertical ? line.box.midX : line.box.midY
            if let i = groups.firstIndex(where:{ group in let first = group[0];return abs(center-(vertical ? first.box.midX : first.box.midY))<max(0.002,(vertical ? min(first.box.width,line.box.width) : min(first.box.height,line.box.height))*0.6) }) { groups[i].append(line) } else { groups.append([line]) }
        }
        let segments = groups.map { group -> ReadingOCRSegment in
            let values = group.sorted{vertical ? $0.box.midY>$1.box.midY : $0.box.minX<$1.box.minX}
            let text = values.map(\.text).joined(separator:vertical ? "" : " ")
            return ReadingOCRSegment(text:text,original:text,box:values.map(\.box).reduce(CGRect.null){$0.union($1)})
        }
        return ordered(segments,by:vertical ? .rightToLeft : .horizontal)
    }
    static func ordered(_ segments:[ReadingOCRSegment],by order:ReadingOCROrder) -> [ReadingOCRSegment] {
        segments.enumerated().sorted { a,b in
            let x = order == .horizontal ? a.element.box.midY : a.element.box.midX,y = order == .horizontal ? b.element.box.midY : b.element.box.midX
            if abs(x-y)<0.0001 { return a.offset<b.offset }
            return order == .leftToRight ? x<y : x>y
        }.map(\.element)
    }
    static func text(_ segments:[ReadingOCRSegment]) -> String { segments.map(\.text).joined(separator:"\n") }
}
