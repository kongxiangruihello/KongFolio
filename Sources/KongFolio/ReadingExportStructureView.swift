import SwiftUI

struct ReadingExportStructureView: View {
    @Binding var options:ReadingExportOptions
    var body:some View {
        DisclosureGroup("成稿结构与栏目标题") {
            Toggle("PDF 评论导出为 Word 原生批注",isOn:Binding(get:{options.nativeWordComments ?? true},set:{options.nativeWordComments=$0}))
            Toggle("附上标注图形和来源区域图片",isOn:Binding(get:{options.includeRegionImages ?? false},set:{options.includeRegionImages=$0}))
            Toggle("附带编号的出处索引",isOn:Binding(get:{options.includeSourceIndex ?? false},set:{options.includeSourceIndex=$0}))
                .disabled(!options.includeSources)
            Toggle("附参考文献表",isOn:Binding(get:{options.bibliography053 ?? false},set:{options.bibliography053=$0}))
            Toggle("同文献后续引用使用短注",isOn:Binding(get:{options.shortenedCitations053 ?? false},set:{options.shortenedCitations053=$0}))
            Toggle("显示每条记录标题",isOn:Binding(get:{options.showRecordTitles ?? true},set:{options.showRecordTitles = $0}))
            HStack { TextField("原文栏目",text:Binding(get:{options.quoteHeading ?? "原文"},set:{options.quoteHeading = $0}));TextField("评论栏目",text:Binding(get:{options.noteHeading ?? "我的笔记"},set:{options.noteHeading = $0})) }
            HStack { TextField("出处栏目",text:Binding(get:{options.sourcesHeading ?? "出处"},set:{options.sourcesHeading = $0}));TextField("图片说明",text:Binding(get:{options.imageHeading ?? "图片摘录"},set:{options.imageHeading = $0})) }
            ForEach(options.structuralOrder,id:\.self) { key in HStack { Text(["quote":"原文与图片","note":"个人评论","sources":"出处与脚注"][key] ?? key);Spacer();Button("上移") { move(key,-1) };Button("下移") { move(key,1) } } }
            Text("结构用于 Word／PDF，随现有模板保存。Markdown 保留便于交换的原文与笔记结构。PDF 汇列注释；Word 使用页底脚注，换页可能不同。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func move(_ key:String,_ delta:Int) { var order = options.structuralOrder;guard let i = order.firstIndex(of:key),order.indices.contains(i+delta) else { return };order.swapAt(i,i+delta);options.blockOrder = order }
}
