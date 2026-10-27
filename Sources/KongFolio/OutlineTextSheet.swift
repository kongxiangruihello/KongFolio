import SwiftUI

/// Edit the whole table of contents as text, or paste one in.
struct OutlineTextSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var offset = 0
    @State private var text = ""
    @State private var loaded = false

    private var preview: OutlineText.Result { OutlineText.parse(text, offset: offset, pageCount: max(workspace.count, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("目录文本").font(.title2.bold())
            Text("每行一条：标题 页码。行首缩进（一个制表符或两个空格）表示下一级。页码后面可以带 “……” 之类的点线。把整份目录粘贴进来也行。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PanelRow {
                Text("页码偏移")
                TextField("0", value: $offset, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
                Text("物理页 = 书上印的页码 + 偏移。例如正文第 1 页是 PDF 的第 12 页，偏移填 11。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 260)
                .border(Color.secondary.opacity(0.4))
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("留空并应用，会清除整个目录。").foregroundStyle(.secondary)
                } else {
                    Text("可用 \(preview.entries.count) 条" + (preview.problems.isEmpty ? "" : "，\(preview.problems.count) 行读不了："))
                    ForEach(Array(preview.problems.prefix(4).enumerated()), id: \.offset) { _, problem in Text(problem).foregroundStyle(.orange) }
                }
            }
            .font(.caption)
            PanelRow {
                Button("取消") { workspace.showOutlineText = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用") { workspace.applyOutlineText(text, offset: offset); workspace.showOutlineText = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .adaptiveSheet(width: 520, height: 600, minimumWidth: 360, flexibleHeight: true)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = OutlineText.serialize(workspace.outlineEntries, offset: offset)
        }
        .onChange(of: offset) { old, new in
            // Re-number the printed pages when the offset changes, as long as the text is the untouched export.
            if text == OutlineText.serialize(workspace.outlineEntries, offset: old) { text = OutlineText.serialize(workspace.outlineEntries, offset: new) }
        }
    }
}
