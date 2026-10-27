import SwiftUI
import PDFKit

struct CommandPaletteView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var query = ""
    @State private var highlighted = 0
    @State private var recent: [String] = []
    @FocusState private var focused: Bool
    private var results: [FolioCommand] { FolioCommand.ranked(query: query, recent: recent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("搜索命令，如：表格、旋转、导出 Word", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14).focused($focused)
                .onSubmit { choose() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { store.showCommandPalette = false; return .handled }
            Divider()
            if results.isEmpty { Text("没有匹配的命令").foregroundStyle(.secondary).padding() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { command in
                            let i = results.firstIndex(of: command) ?? 0
                            let reason = store.unavailableReason(command)
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title)
                                    if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if recent.contains(command.rawValue) { Text("最近使用").font(.caption).foregroundStyle(.secondary) }
                            }.padding(10).foregroundStyle(reason == nil ? .primary : .secondary)
                                .background(i == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle()).onTapGesture { highlighted = i; choose() }.id(command.id)
                                .accessibilityElement(children: .combine)
                        }
                    }.padding(6)
                }.onChange(of: highlighted) { _, i in if results.indices.contains(i) { proxy.scrollTo(results[i].id) } }
            }
            Divider()
            PanelRow { Text("↑ ↓ 选择 · 回车执行 · Esc 关闭").font(.caption).foregroundStyle(.secondary); Spacer(); Button("关闭") { store.showCommandPalette = false } }.padding(10)
        }.adaptiveSheet(width: 570, height: 440, minimumWidth: 350)
            .onAppear { recent = store.recentCommands; focused = true }
            .onChange(of: query) { _, _ in highlighted = 0 }
    }
    private func move(_ delta: Int) { highlighted = min(max(0, highlighted + delta), max(0, results.count - 1)) }
    private func choose() {
        guard results.indices.contains(highlighted) else { return }
        let command = results[highlighted]
        guard store.unavailableReason(command) == nil else { return }
        store.showCommandPalette = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.performCommand(command) }
    }
}
