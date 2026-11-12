import SwiftUI

struct ReaderToolbarSettings: View {
    @Binding var profile:ReaderToolbarProfile
    var width:Double=800
    var context:ReaderToolbarContext = .pdf
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("工具栏排列与显示").font(.headline)
            Text("勾选的工具才显示在工具栏。上移／下移调整顺序。窄窗口优先保留已勾选的搜索、标注和右侧面板，其余入口见“更多”。").font(.caption)
            Text("当前窗口显示 \(profile.visible(width:width,context:context).count) 项，另有 \(profile.hidden(width:width,context:context).filter { context.supports($0) }.count) 项收在“更多”中").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing:12) { ForEach(profile.visible(width:width,context:context)) { action in
                    action.label(action.title).font(.caption).fixedSize()
                } }.padding(8)
            }.background(.quaternary,in:RoundedRectangle(cornerRadius:6)).accessibilityLabel("当前工具栏排列预览")
            List { ForEach(profile.actions) { action in HStack {
                Toggle(isOn:Binding(get:{profile.pinned.contains(action.rawValue)},set:{if $0 { profile.pinned.insert(action.rawValue) } else { profile.pinned.remove(action.rawValue) };profile.save()})) { action.label(action.title) }
                Spacer();Button("上移") { profile.move(action,by:-1);profile.save() }.disabled(profile.actions.first == action).accessibilityLabel("上移"+action.title)
                Button("下移") { profile.move(action,by:1);profile.save() }.disabled(profile.actions.last == action).accessibilityLabel("下移"+action.title)
            } } }
            HStack { Button("恢复默认") { profile = ReaderToolbarProfile();profile.save() };Spacer();Button("完成") { dismiss() } }
        }.padding(20).adaptiveSheet(width:650,height:600,minimumWidth:400)
    }
}
