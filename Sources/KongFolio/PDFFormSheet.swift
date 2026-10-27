import SwiftUI
import PDFKit

struct PDFFormSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var fields: [PDFFormField] = []
    @State private var values: [String: String] = [:]
    @State private var sourceRevision = UUID()
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("填写 PDF 表单").font(.title2.bold())
            Text("填写已有的交互字段；修改后点击“应用填写”。签名字段、按钮动作和 XFA 表单暂不支持。").font(.caption).foregroundStyle(.secondary)
            Button("制作 / 套用扫描表单模板…") { workspace.showPDFForms = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { workspace.showFormTemplate = true } }
            if fields.isEmpty { Text("没有发现可填写字段。普通扫描表格可使用标注中的文字工具填写。").padding(.vertical, 24) }
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text("第 \(field.page + 1) 页 · \(field.name)\(field.readOnly ? "（只读）" : "")").font(.caption)
                    control(field).disabled(field.readOnly)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("固定结果副本会将整页转成清晰图片，保留外观；该副本中的文字和字段不可再编辑，数字签名也不会保留有效性。").font(.caption).foregroundStyle(.secondary)
            PanelRow {
                Button("取消 / 关闭") { workspace.showPDFForms = false }.keyboardShortcut(.cancelAction)
                Button("应用填写") { apply() }.disabled(fields.isEmpty)
                Button("应用并保存") { if apply() { _ = workspace.saveDirectly() } }.disabled(fields.isEmpty)
                Button("固定结果副本…") { export() }.disabled(fields.isEmpty)
                Button("准备打印副本…") { printCopy() }.disabled(fields.isEmpty)
            }
        }.padding(24).adaptiveSheet(width: 600, height: 680, minimumWidth: 360, flexibleHeight: true).onAppear(perform: refresh)
    }
    @ViewBuilder private func control(_ f: PDFFormField) -> some View {
        let binding = Binding(get: { values[f.id] ?? f.value }, set: { values[f.id] = $0 })
        if ["勾选", "单选"].contains(f.kind) {
            Toggle(f.kind == "单选" ? "选择此项" : "勾选", isOn: Binding(get: { binding.wrappedValue == "1" }, set: { on in
                if on, f.kind == "单选" { for other in fields where other.kind == "单选" && other.name == f.name && !other.readOnly { values[other.id] = "0" } }
                binding.wrappedValue = on ? "1" : "0"
            }))
        } else if f.kind == "选项" {
            Picker("选项", selection: binding) {
                Text("未选择").tag("")
                ForEach(Array(f.choices.enumerated()), id: \.offset) { i, choice in Text(choice).tag(f.exports.indices.contains(i) ? f.exports[i] : choice) }
                if !f.value.isEmpty, !f.exports.contains(f.value) { Text(f.value).tag(f.value) }
            }
        } else if f.password { SecureField("填写内容", text: binding) }
        else if f.kind == "文字" { TextField("填写内容", text: binding, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder) }
        else { Text("此类型暂不支持填写").foregroundStyle(.secondary) }
    }
    private func refresh() { fields = PDFForms.fields(workspace.document); values = [:]; sourceRevision = workspace.revision }
    @discardableResult private func apply() -> Bool {
        do { try workspace.applyFormValues(values, from: sourceRevision); refresh(); message = "填写已应用到文档，可继续保存或打印。"; return true }
        catch { message = error.localizedDescription; return false }
    }
    private func export() {
        guard apply(), let destination = workspace.saveURL(type: .pdf, suffix: "pdf", name: workspace.title + "-固定表单") else { return }
        do {
            guard let store = workspace.store else { return }
            try workspace.startFlattenedForm(to: destination, queue: store.documentTasks); workspace.showPDFForms = false
        } catch { message = error.localizedDescription }
    }
    private func printCopy() {
        guard apply(), let store = workspace.store else { return }
        do {
            let folder = workspace.storage.appendingPathComponent("TaskResults", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try workspace.startFlattenedForm(to: folder.appendingPathComponent(UUID().uuidString + ".pdf"), queue: store.documentTasks)
            workspace.showPDFForms = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.showBackgroundJobs = true }
        } catch { message = error.localizedDescription }
    }

}
