import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct DocumentComparisonPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL?] = [nil, nil]
    @State private var before: PDFDocument?
    @State private var after: PDFDocument?
    @State private var rows: [PageDifference] = []
    @State private var selection = 0
    @State private var working = false
    @State private var message = ""
    @State private var worker: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文档精细对比").font(.title2.bold())
            PanelRow {
                ForEach(0..<2) { index in Button(urls[index]?.lastPathComponent ?? (index == 0 ? "选择原件…" : "选择对照文件…")) { choose(index) }.disabled(working) }
                Button("开始对比") { compare() }.disabled(working || urls.contains(where: { $0 == nil }))
                if working { ProgressView().controlSize(.small) }
            }
            if let before, let after { ComparisonViewer(before: before, after: after, rows: rows, selection: $selection) }
            else { Spacer(); Text("选择两份 PDF，可核对文字修改或扫描图像的局部差异。").foregroundStyle(.secondary); Spacer() }
            Text(message).font(.caption)
            Button(working ? "取消对比" : "关闭") { if working { worker?.cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction)
        }.padding(20).adaptiveSheet(width: 1100, height: 800, minimumWidth: 360).onDisappear { worker?.cancel() }
    }
    private func choose(_ index: Int) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK { urls[index] = panel.url; before = nil; after = nil; rows = [] }
    }
    private func compare() {
        guard let a = urls[0], let b = urls[1] else { return }
        working = true; message = "正在逐页对比…"; before = nil; after = nil
        worker = Task {
            let job = Task.detached(priority: .userInitiated) { () throws -> (Data, Data, [PageDifference]) in
                let left = try Data(contentsOf: a), right = try Data(contentsOf: b)
                return (left, right, try PDFComparison.compare(left, right))
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }); try Task.checkCancellation()
                before = PDFDocument(data: result.0); after = PDFDocument(data: result.1); rows = result.2; selection = rows.first?.id ?? 0; message = "已完成；选择字词差异或图像叠加查看细节。"
            } catch is CancellationError { message = "已取消" } catch { message = error.localizedDescription }
            working = false
        }
    }
}
