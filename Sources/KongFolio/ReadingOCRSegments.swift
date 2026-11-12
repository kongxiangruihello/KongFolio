import SwiftUI

struct ReadingOCRSegmentEditor: View {
    @ObservedObject var controller:ReadingImageOCRController
    @State private var order = ReadingOCROrder.rightToLeft
    @State private var page = 0
    @State private var expanded: Bool
    var onSelect: ((ReadingOCRSegment) -> Void)?

    init(controller:ReadingImageOCRController,onSelect:((ReadingOCRSegment)->Void)? = nil) {
        self.controller = controller
        self.onSelect = onSelect
        _expanded = State(initialValue:onSelect != nil)
    }
    private var pagination:ReadingPagination { ReadingPagination(total:controller.segments.count,page:page,size:10) }
    var body:some View {
        DisclosureGroup("逐列／逐段校订 · \(controller.segments.count) 段",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Picker("排列",selection:$order) { ForEach(ReadingOCROrder.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Button("按所选顺序重建校订文字") { controller.segments = ReadingOCRSegments.ordered(controller.segments,by:order);controller.text = ReadingOCRSegments.text(controller.segments) }
                Text("此按钮会用下方逐段内容替换上方校订文字；原始识别文字保留，繁简字形不自动转换。").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(controller.segments.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { segment in
                    VStack(alignment:.leading,spacing:3) {
                        if let onSelect {
                            Button("在原图中定位第 \(1+(controller.segments.firstIndex(where:{$0.id == segment.id}) ?? 0)) 段") { onSelect(segment) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                        StableTextField("校订这一段",text:Binding(get:{controller.segments.first{$0.id == segment.id}?.text ?? ""},set:{ text in if let i = controller.segments.firstIndex(where:{$0.id == segment.id}) { controller.segments[i].text = text } }))
                        HStack { Text("识别原文："+segment.original).font(.caption).lineLimit(2);Spacer();Button("上移") { controller.moveSegment(segment.id,delta:-1) };Button("下移") { controller.moveSegment(segment.id,delta:1) } }
                    }
                }
                Button("把逐段校订合并到正文") { controller.text = ReadingOCRSegments.text(controller.segments) }
                HStack { Text(pagination.label);Button("上一页") { page = max(0,page-1) }.disabled(pagination.index == 0);Button("下一页") { page += 1 }.disabled(pagination.index>=pagination.last) }.font(.caption)
            }
        }
    }
}
