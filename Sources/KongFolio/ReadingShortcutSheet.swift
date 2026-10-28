import SwiftUI
import AppKit

struct ReadingShortcutSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var mode = ReadingShortcut.Mode.resume
    @State private var saved: URL?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("这本书的阅读快捷方式").font(.headline)
            Text(workspace.displayName).lineLimit(2)
            Picker("打开位置", selection: $mode) { ForEach(ReadingShortcut.Mode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text(mode == .resume ? "每次打开都回到这本书最新读到的位置，无须重新保存链接。" : "每次打开都回到现在的第 \(workspace.selection + 1) 页及当前阅读位置。")
                .font(.callout).foregroundStyle(.secondary)
            Text("保存为快捷方式后，将文件拖到 Mac 底部 Dock 的右侧（分隔线后、废纸篓旁），以后点一下就能用 KongFolio 阅读。书籍仍保存在原位置。")
            PanelRow {
                Button("拷贝阅读链接") { perform { try workspace.copyReadingLink(mode: mode); message = "阅读链接已拷贝，可粘贴到笔记。" } }
                Button("保存快捷方式…") { perform { if let url = try workspace.saveReadingShortcut(mode: mode) { saved = url; message = "已保存。点击“在访达中显示”，再把该文件拖到 Dock 右侧。" } } }.buttonStyle(.borderedProminent)
            }
            if let saved {
                Label("将这本书的快捷方式拖到 Dock 右侧", systemImage: "book.closed")
                    .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onDrag { NSItemProvider(object: saved as NSURL) }
                    .help("拖到 Dock 分隔线后、废纸篓旁")
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("完成") { workspace.showReadingShortcut = false }.keyboardShortcut(.cancelAction) }
        }.padding().adaptiveSheet(width: 570, height: 480, minimumWidth: 360)
        .onChange(of: mode) { _, _ in saved = nil; message = "" }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { message = error.localizedDescription } }
}
