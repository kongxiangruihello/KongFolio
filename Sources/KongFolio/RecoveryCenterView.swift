import SwiftUI
import PDFKit

struct RecoveryCenterView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var items: [RecoveryItem] = []
    @State private var selected: String?
    @State private var query = ""
    @State private var preview: RecoveryPreview?
    @State private var message = ""
    @State private var working = false
    @State private var page = 0
    private var selectedItem: RecoveryItem? { items.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("恢复中心").font(.title2.bold())
            Text("集中查看冲突副本、Word 与表格草稿。打开时创建独立副本，原件和恢复记录保留。").font(.caption).foregroundStyle(.secondary)
            TextField("搜索文件名或类型", text: $query).textFieldStyle(.roundedBorder)
            Picker("恢复记录", selection: $selected) {
                Text("选择一条记录").tag(nil as String?)
                ForEach(items.filter { query.isEmpty || ($0.title + $0.kind.rawValue).localizedCaseInsensitiveContains(query) }) { item in
                    Text(item.kind.rawValue + " · " + item.title + " · " + item.modified.formatted(date: .abbreviated, time: .shortened)).tag(item.id as String?)
                }
            }
            if working { ProgressView("正在读取和核对…") }
            if let preview {
                Text(preview.sourceStatus).font(.caption).foregroundStyle(.secondary)
                if let a = preview.pdf, let before = PDFDocument(data: a) {
                    if let b = preview.original, let after = PDFDocument(data: b) {
                        ComparisonViewer(before: before, after: after, rows: preview.differences, leftTitle: "恢复副本", rightTitle: "目前原件", selection: $page).frame(height: 380)
                    } else { RecoveryPDFView(document: before).frame(height: 380) }
                } else { ScrollView { Text(preview.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 300) }
            } else if !working { Text(items.isEmpty ? "没有恢复记录" : "请选择记录预览并核对").foregroundStyle(.secondary).frame(height: 200) }
            if let item = selectedItem { Text(item.sourcePath ?? "未记录原件位置").font(.caption).textSelection(.enabled) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            PanelRow {
                Button("关闭") { store.showRecoveryCenter = false }.keyboardShortcut(.cancelAction)
                Button("刷新列表") { Task { await reload() } }
                Button("在访达中显示记录") { if let item = selectedItem { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }.disabled(selectedItem == nil)
                Button("打开独立副本") {
                    guard let item = selectedItem, let payload = preview?.payload else { return }
                    store.showRecoveryCenter = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { do { try store.openRecoveryCopy(item, payload: payload) } catch { store.present(error) } }
                }.disabled(working || preview == nil || selectedItem == nil)
            }
        }.padding(24).adaptiveSheet(width: 1000, height: 760, minimumWidth: 360, flexibleHeight: true)
            .task { await reload() }.task(id: selected) { await inspect() }
    }
    private func reload() async {
        let storage = store.storage, paths = store.tabs.compactMap { $0.workspace?.displayPath }
        do {
            let worker = Task.detached { try RecoveryCatalog.list(storage: storage, knownPaths: paths) }
            let list = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }); try Task.checkCancellation()
            items = list
            if let target = store.pendingRecoveryURL {
                selected = items.first { $0.url.standardizedFileURL == target.standardizedFileURL }?.id
                store.pendingRecoveryURL = nil
            }
            if !items.contains(where: { $0.id == selected }) { selected = items.first?.id }
            message = "共 \(items.count) 条记录"
        } catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func inspect() async {
        preview = nil; guard let item = selectedItem else { return }; working = true
        let key = selected
        do {
            let worker = Task.detached { try RecoveryCatalog.preview(item) }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }); try Task.checkCancellation()
            guard key == selected else { return }; preview = result; page = result.differences.first?.id ?? 0
        } catch is CancellationError {} catch { if key == selected { message = "记录无法读取，原稿保留：\(error.localizedDescription)" } }
        if key == selected { working = false }
    }
}
private struct RecoveryPDFView: NSViewRepresentable {
    var document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
