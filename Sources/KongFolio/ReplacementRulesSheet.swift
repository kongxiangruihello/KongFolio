import SwiftUI

/// The corrections applied to exported text.
struct ReplacementRulesSheet: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出时的替换规则").font(.title2.bold())
            Text("每行一条：错字=正字（也可写 → 或 ->）。右边留空表示删除。# 开头的行是备注。规则按从上到下的顺序，对导出的整段文字逐条替换。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $workspace.replacementText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 220)
                .border(Color.secondary.opacity(0.4))
            Text("现有 \(ReplacementRules.parse(workspace.replacementText).count) 条规则。只影响导出的 Word、TXT、Markdown，不改动 PDF 和识别记录；规则保存在本机，所有书通用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("导出时应用", isOn: $workspace.applyReplacements)
                Spacer()
                Button("完成") { workspace.showReplacementRules = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
