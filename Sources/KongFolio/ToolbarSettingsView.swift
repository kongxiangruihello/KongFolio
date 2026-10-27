import SwiftUI

struct ToolbarSettingsView: View {
    @Binding var saved: String
    @Environment(\.dismiss) private var dismiss
    private var preferences: ToolbarPreferences { ToolbarPreferences.decode(saved) }
    private func update(_ change: (inout ToolbarPreferences) -> Void) {
        var value = preferences; change(&value); saved = value.encoded
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定工具栏").font(.title2.bold())
            Text("勾选显示的按钮，拖动列表或用箭头调整顺序。标注和快捷工具始终显示；窄窗口会自动使用图标并分排。").font(.caption).foregroundStyle(.secondary)
            Toggle("只显示图标", isOn: Binding(get: { preferences.iconsOnly }, set: { on in update { $0.iconsOnly = on } }))
            List {
                ForEach(preferences.order) { action in
                    HStack {
                        Toggle(isOn: Binding(get: { !preferences.hidden.contains(action) || action.pinned }, set: { on in update { if on { $0.hidden.remove(action) } else { $0.hidden.insert(action) } } })) {
                            Label(action.title, systemImage: action.symbol)
                        }.disabled(action.pinned)
                        Spacer()
                        if action.pinned { Text("固定").font(.caption).foregroundStyle(.secondary) }
                        Button { update { $0.move(action, by: -1) } } label: { Image(systemName: "arrow.up") }.help("上移 \(action.title)")
                        Button { update { $0.move(action, by: 1) } } label: { Image(systemName: "arrow.down") }.help("下移 \(action.title)")
                    }
                }.onMove { source, destination in update { $0.order.move(fromOffsets: source, toOffset: destination) } }
            }
            HStack { Button("恢复默认") { saved = ToolbarPreferences().encoded }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 460, height: 620)
    }
}
