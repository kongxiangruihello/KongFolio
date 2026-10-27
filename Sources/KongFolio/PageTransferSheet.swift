import SwiftUI

struct PageTransferSheet: View {
    @ObservedObject var store: WorkspaceStore
    let request: PageTransferRequest
    @State private var moving = false
    @State private var position = 0
    private var target: Workspace? { store.tabs.compactMap(\.workspace).first { $0.id == request.target } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("传送 \(request.drag.pages.count) 个页面").font(.title2.bold())
            Text("目标：\(target?.displayName ?? "文档已关闭")")
            if let target {
                Picker("插入位置", selection: $position) {
                    ForEach(0...target.count, id: \.self) { index in Text(index == target.count ? "文档末尾" : "第 \(index + 1) 页之前").tag(index) }
                }
            }
            Toggle("移动页面（从源文档移除）", isOn: $moving)
            Text("标注、目录与 OCR 记录随页面复制。移动后，两份文档可分别撤销。").font(.caption).foregroundStyle(.secondary)
            PanelRow { Button("取消") { store.pendingPageTransfer = nil }; Spacer(); Button(moving ? "移动页面" : "复制页面") { _ = store.transferPages(request, move: moving, insertion: position) }.keyboardShortcut(.defaultAction) }
        }.padding(24).adaptiveSheet(width: 440, height: 600, minimumWidth: 360)
        .alert("页面传送失败", isPresented: Binding(get: { target?.error != nil }, set: { if !$0 { target?.error = nil } })) { Button("好") { target?.error = nil } } message: { Text(target?.error ?? "") }
        .onAppear { position = request.insertion }
    }
}
