import SwiftUI

struct ReadingLibraryContextMenu: View {
    let context:ReadingLibraryContext
    let readOnly:Bool
    let perform:(ReadingLibraryContextAction)->Void
    private var countLabel:String { context.items.count == 1 ? "这条资料" : "这 \(context.items.count) 条资料" }
    var body:some View {
        if !context.items.isEmpty {
            if context.items.count>1 { Text("已选 \(context.items.count) 条资料") }
            if context.single != nil {
                Button(context.removed || readOnly ? "查看资料" : "编辑资料") { perform(.edit) }
                let sources = context.sources()
                if sources.count == 1,let source = sources.first { Button("返回原文") { perform(.source(source.source)) } }
                else if !sources.isEmpty {
                    Menu("返回原文") {
                        ForEach(Array(sources.enumerated()),id:\.offset) { index,citation in
                            Button("\(index+1). "+citation.display) { perform(.source(citation.source)) }
                        }
                    }
                }
                Button("查看引用关系…") { perform(.references) }
            }
            Button(context.items.count == 1 ? "复制正文与出处" : "复制 \(context.items.count) 条正文与出处") { perform(.copy) }
            Button("导出"+countLabel+"…") { perform(.export) }.disabled(context.removed)
            Button("整理标签与专题…") { perform(.organize) }.disabled(context.removed || readOnly)
            if context.canAppend { Button("加入札记…") { perform(.append) }.disabled(readOnly) }
            Divider()
            Menu("新增资料") { newItems }
            Divider()
            if context.removed { Button("恢复"+countLabel+"…") { perform(.remove) }.disabled(readOnly) }
            else { Button("移到最近删除（\(context.items.count) 条）…",role:.destructive) { perform(.remove) }.disabled(readOnly) }
        } else { newItems }
    }
    @ViewBuilder private var newItems:some View {
        Button("新建摘录") { perform(.newExcerpt) }.disabled(readOnly)
        Button("新建笔记") { perform(.newNote) }.disabled(readOnly)
        Button("新建札记") { perform(.newEssay) }.disabled(readOnly)
    }
}
