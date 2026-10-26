import SwiftUI

struct OCRBatchCorrectionSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var hits: [OCRRuleHit] = []
    @State private var selected = Set<String>()
    @State private var expected = UUID()
    @State private var selectedOnly = false
    @State private var previewed = false
    @State private var rulesUsed = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OCR 批量纠错").font(.title2.bold())
            Text("每行填写“错字=正字”，规则保存在本机。先预览，再勾选要改的位置；重叠内容优先使用上面的规则，替换结果不再次匹配。").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $workspace.replacementText).font(.system(.body, design: .monospaced)).frame(height: 100).border(.secondary.opacity(0.4))
            HStack {
                Toggle("仅选中页", isOn: $selectedOnly)
                Button("预览全部命中") { preview() }.disabled(workspace.busy)
                Button("全选") { selected = Set(hits.map(\.id)) }
                Button("全不选") { selected = [] }
                Spacer(); Text("已选 \(selected.count) / \(hits.count) 处")
            }
            List(hits) { hit in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { selected.contains(hit.id) }, set: { if $0 { selected.insert(hit.id) } else { selected.remove(hit.id) } })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(hit.page + 1) 页 · 第 \(hit.line + 1) 行：\(hit.from) → \(hit.to.isEmpty ? "（删除）" : hit.to)")
                            Text(hit.context).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Button("定位原文") { workspace.selectPage(hit.page) }
                }
            }
            if previewed && hits.isEmpty { Text("没有命中。仅扫描保留 OCR 前原页的识别记录。").foregroundStyle(.secondary) }
            HStack {
                Button("取消") { workspace.showOCRBatchCorrection = false }.disabled(workspace.busy)
                Spacer()
                Button("应用选中纠错") { workspace.applyOCRBatch(hits.filter { selected.contains($0.id) }, expected: expected) }
                    .disabled(workspace.busy || selected.isEmpty || rulesUsed != workspace.replacementText || workspace.revision != expected)
            }
        }.padding(20).frame(width: 780, height: 620)
        .onChange(of: selectedOnly) { _, _ in hits = []; selected = []; previewed = false }
        .alert("纠错失败", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) { Button("好") { workspace.error = nil } } message: { Text(workspace.error ?? "") }
    }
    private func preview() {
        expected = workspace.revision; rulesUsed = workspace.replacementText
        let eligible = workspace.ocrRegions.filter { workspace.meta($0.key).ocrOriginal != nil }
        hits = OCRBatchCorrection.matches(regions: eligible, rules: ReplacementRules.parse(rulesUsed), pages: selectedOnly ? Set(workspace.effectivePages) : nil)
        selected = Set(hits.map(\.id)); previewed = true
    }
}
