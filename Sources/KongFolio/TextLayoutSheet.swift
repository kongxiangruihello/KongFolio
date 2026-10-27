import SwiftUI

struct TextLayoutSheet: View {
    @ObservedObject var note: MarkdownNote
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("排版设置").font(.title2.bold())
            Picker("字体", selection: $note.layoutOptions.fontName) {
                Text("宋体").tag("Songti SC"); Text("苹方").tag("PingFang SC"); Text("Helvetica").tag("Helvetica")
            }
            Stepper("正文大小：\(Int(note.layoutOptions.fontSize)) 磅", value: $note.layoutOptions.fontSize, in: 8...36, step: 1)
            HStack { Text("行距：\(note.layoutOptions.lineHeight, specifier: "%.1f") 倍"); Slider(value: $note.layoutOptions.lineHeight, in: 1...2.5, step: 0.1) }
            HStack { Text("页边距：\(note.layoutOptions.margin * 25.4 / 72, specifier: "%.0f") 毫米"); Slider(value: $note.layoutOptions.margin, in: 20...120, step: 2.835) }
            Text("预览、PDF、Word 和打印共用这些设置，下次自动沿用。纸张为 A4。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("恢复默认") { note.layoutOptions = TextLayoutOptions() }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 430)
    }
}
