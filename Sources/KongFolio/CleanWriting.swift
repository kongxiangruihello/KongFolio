import Foundation
import Combine

struct CleanWritingBlock:Identifiable {
    enum Kind { case text,image,metadata }
    var id = UUID();var kind:Kind;var source:String;var suffix = "";var reference = "";var title = ""
}
@MainActor final class CleanWritingSession:ObservableObject {
    @Published var blocks:[CleanWritingBlock] = []
    private(set) var source = ""
    func load(_ text:String) {
        guard text != source || blocks.isEmpty else { return };source = text
        let ns = text as NSString;var protected:[(NSRange,CleanWritingBlock)] = EditorImage.list(text,format:.markdown).map { image in (image.range,CleanWritingBlock(kind:.image,source:ns.substring(with:image.range),reference:image.reference,title:image.caption)) }
        let regex = try! NSRegularExpression(pattern:EditorCorrections.pattern)
        for m in regex.matches(in:text,range:NSRange(location:0,length:ns.length)) where !protected.contains(where:{NSIntersectionRange($0.0,m.range).length>0}) { protected.append((m.range,CleanWritingBlock(kind:.metadata,source:ns.substring(with:m.range),title:"校勘记录（随正文保留）"))) }
        protected.sort{$0.0.location<$1.0.location};var result:[CleanWritingBlock] = [],position = 0
        func appendText(_ range:NSRange) {
            guard range.length>0 else { return };let value = ns.substring(with:range),parts = value.components(separatedBy:"\n\n")
            for (i,part) in parts.enumerated() { let suffix = i+1<parts.count ? "\n\n" : "";if !part.isEmpty || !suffix.isEmpty { result.append(CleanWritingBlock(kind:.text,source:part,suffix:suffix)) } }
        }
        for (range,block) in protected { guard range.location>=position else { continue };appendText(NSRange(location:position,length:range.location-position));result.append(block);position = NSMaxRange(range) }
        appendText(NSRange(location:position,length:ns.length-position))
        if result.isEmpty { result = [CleanWritingBlock(kind:.text,source:"")] }
        if result.count == blocks.count { for i in result.indices where result[i].kind == blocks[i].kind && (result[i].kind != .text || result[i].source == blocks[i].source) { result[i].id = blocks[i].id } }
        blocks = result
    }
    func edit(_ id:UUID,text:String)->String {
        guard let i = blocks.firstIndex(where:{$0.id == id}),blocks[i].kind == .text else { return source }
        blocks[i].source = text;source = blocks.map{$0.source+$0.suffix}.joined();return source
    }
}
