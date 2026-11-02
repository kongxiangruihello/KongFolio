import SwiftUI

struct ReaderToolbarSettings: View {
    @Binding var profile:ReaderToolbarProfile
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("常用工具排列").font(.headline)
            Text("固定的按钮优先显示；窗口过窄时仍会收入“更多”，主工具栏始终一行。上方标签栏负责显示文件名。").font(.caption)
            List { ForEach(profile.actions) { action in HStack {
                Toggle(isOn:Binding(get:{profile.pinned.contains(action.rawValue)},set:{if $0 { profile.pinned.insert(action.rawValue) } else { profile.pinned.remove(action.rawValue) };profile.save()})) { Label(action.title,systemImage:action.symbol) }
                Spacer();Button("上移") { profile.move(action,by:-1);profile.save() };Button("下移") { profile.move(action,by:1);profile.save() }
            } } }
            HStack { Button("恢复默认") { profile = ReaderToolbarProfile();profile.save() };Spacer();Button("完成") { dismiss() } }
        }.padding(20).adaptiveSheet(width:650,height:600,minimumWidth:400)
    }
}
