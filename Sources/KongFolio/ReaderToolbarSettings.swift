import SwiftUI

struct ReaderToolbarSettings: View {
    @Binding var profile:ReaderToolbarProfile
    var width:Double=800
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("工具栏排列与固定").font(.headline)
            Text("列表从上到下，对应工具栏从左到右。固定只决定窗口变窄时优先保留哪些工具，不改变排列顺序；空间不足的功能仍在“更多”中。").font(.caption)
            Text("当前窗口显示 \(profile.visible(width:width).count) 项，另有 \(profile.hidden(width:width).count) 项收在“更多”中").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing:12) { ForEach(profile.visible(width:width)) { action in
                    Label(action.title,systemImage:action.symbol).font(.caption).fixedSize()
                } }.padding(8)
            }.background(.quaternary,in:RoundedRectangle(cornerRadius:6)).accessibilityLabel("当前工具栏排列预览")
            List { ForEach(profile.actions) { action in HStack {
                Toggle(isOn:Binding(get:{profile.pinned.contains(action.rawValue)},set:{if $0 { profile.pinned.insert(action.rawValue) } else { profile.pinned.remove(action.rawValue) };profile.save()})) { Label(action.title,systemImage:action.symbol) }
                Spacer();Button("上移") { profile.move(action,by:-1);profile.save() }.disabled(profile.actions.first == action).accessibilityLabel("上移"+action.title)
                Button("下移") { profile.move(action,by:1);profile.save() }.disabled(profile.actions.last == action).accessibilityLabel("下移"+action.title)
            } } }
            HStack { Button("恢复默认") { profile = ReaderToolbarProfile();profile.save() };Spacer();Button("完成") { dismiss() } }
        }.padding(20).adaptiveSheet(width:650,height:600,minimumWidth:400)
    }
}
