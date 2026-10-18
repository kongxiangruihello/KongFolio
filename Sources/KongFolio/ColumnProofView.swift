import AppKit
import SwiftUI

/// Proofreading of a vertical page column by column: the picture of the column beside its recognised text, which can be
/// corrected in place. Doubtful columns (low confidence) are marked and can be shown alone.
struct ColumnProofView: View {
    @ObservedObject var workspace: Workspace
    @State private var columns: [ProofColumn] = []
    @State private var onlyDoubtful = false
    @State private var page = 0
    @State private var image: NSImage?

    private var shown: [ProofColumn] {
        onlyDoubtful ? columns.filter { $0.isDoubtful(below: ColumnProofreading.doubtfulThreshold) || $0.isEdited } : columns
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("逐列校对 · 第 \(page + 1) 页").font(.headline)
                Toggle("只看存疑的列", isOn: $onlyDoubtful).toggleStyle(.checkbox)
                Spacer()
                let change = ColumnProofreading.changes(in: columns)
                Text("共 \(columns.count) 列，存疑 \(columns.filter { $0.isDoubtful(below: ColumnProofreading.doubtfulThreshold) }.count) 列，已改 \(columns.filter(\.isEdited).count) 列（\(change.edits) 字）")
                    .font(.caption).foregroundStyle(.secondary)
                Button("取消") { workspace.showProofreading = false }
                Button("应用") {
                    workspace.applyProofreading(columns, page: page)
                    workspace.showProofreading = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!columns.contains(where: \.isEdited))
            }
            .padding()
            Divider()
            if columns.isEmpty {
                Text("这一页没有竖排识别记录。先用“OCR”识别，并在识别设置里选竖排。").foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { column in row(column) }
                    }
                    .padding()
                }
            }
            Text("列按阅读顺序排列（从右到左）。左边是原页上这一列的图，右边可直接改字；改完点“应用”，识别记录与可搜索的文字层一并更新（⌘Z 可撤销）。")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 760, height: 640)
        .onAppear(perform: load)
    }

    private func row(_ column: ProofColumn) -> some View {
        let doubtful = column.isDoubtful(below: ColumnProofreading.doubtfulThreshold)
        return HStack(alignment: .top, spacing: 12) {
            if let crop = crop(column) {
                Image(nsImage: crop).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 220)
                    .overlay(Rectangle().stroke(doubtful ? Color.orange : Color.secondary.opacity(0.4), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("第 \(column.id + 1) 列").font(.caption.bold())
                    Text("置信度 \(Int(column.confidence * 100))%").font(.caption).foregroundStyle(doubtful ? .orange : .secondary)
                    if column.isEdited { Text("已改").font(.caption).foregroundStyle(Brand.accent) }
                    Spacer()
                    if column.isEdited { Button("还原") { set(column.id, text: column.original) }.font(.caption) }
                }
                TextField("", text: Binding(get: { columns[column.id].text }, set: { set(column.id, text: $0) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(size: 18))
                if !column.perCharacter { Text("这一列的位置是近似的，改字后整列作为一段保存。").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(doubtful ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func set(_ id: Int, text: String) {
        guard columns.indices.contains(id) else { return }
        columns[id].text = text
    }

    private func load() {
        page = workspace.selection
        columns = ColumnProofreading.columns(workspace.meta(page).ocrRegions ?? []) ?? []
        image = workspace.pageDisplayImage(maxDimension: 2400)
    }

    private func crop(_ column: ProofColumn) -> NSImage? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rect = ColumnProofreading.cropRect(box: column.box, imageSize: CGSize(width: cg.width, height: cg.height))
        guard let part = cg.cropping(to: rect.integral) else { return nil }
        return NSImage(cgImage: part, size: NSSize(width: part.width, height: part.height))
    }
}
