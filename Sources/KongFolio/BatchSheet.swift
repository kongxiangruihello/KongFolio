import SwiftUI
import AppKit

/// Runs a recipe over every PDF of a folder. Recipes are kept between launches.
struct BatchSheet: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var queue = BatchQueue()
    @State private var recipes = WorkRecipeStore.load()
    @State private var selected: UUID?
    @State private var input: URL?
    @State private var output: URL?

    private var index: Int? { recipes.firstIndex { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文件夹批处理").font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("配方").font(.headline)
                    List(selection: $selected) {
                        ForEach(recipes) { Text($0.name).tag($0.id as UUID?) }
                    }
                    .frame(width: 190, height: 220)
                    HStack {
                        Button("新建") { let recipe = WorkRecipe(name: "新配方"); recipes.append(recipe); selected = recipe.id }
                        Button("删除") { if let index { recipes.remove(at: index); selected = recipes.first?.id } }.disabled(index == nil)
                    }
                }
                editor.frame(width: 340, alignment: .topLeading)
            }
            Divider()
            folders
            if !queue.items.isEmpty {
                List(queue.items) { item in
                    HStack {
                        Text(item.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(label(item.state)).font(.caption).foregroundStyle(color(item.state)).lineLimit(1)
                    }
                }
                .frame(height: 150)
            }
            if queue.running { ProgressView(value: queue.fileProgress) }
            if !queue.summary.isEmpty { Text(queue.summary).font(.callout) }
            Text("结果写到输出文件夹，原文件不会被改动；已有结果的文件会被跳过，所以中途停止后可以接着做。OCR 很慢，整本书可能要几十分钟。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("关闭") { workspace.showBatch = false }.keyboardShortcut(.cancelAction).disabled(queue.running)
                Spacer()
                if queue.running {
                    Button("停止") { queue.cancel() }
                } else {
                    Button("开始处理") { if let index, let output { queue.start(recipe: recipes[index], output: output, replacements: workspace.applyReplacements ? ReplacementRules.parse(workspace.replacementText) : []) } }
                        .buttonStyle(.borderedProminent).disabled(index == nil || input == nil || output == nil || queue.items.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { if selected == nil { selected = recipes.first?.id } }
        .onChange(of: recipes) { WorkRecipeStore.save($0) }
    }

    @ViewBuilder private var editor: some View {
        if let index {
            VStack(alignment: .leading, spacing: 6) {
                TextField("名称", text: $recipes[index].name)
                Text(recipes[index].summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("只处理这些页（如 3-400；留空为全部）", text: $recipes[index].pageRange)
                Toggle("扫描增强（去底色、提高对比）", isOn: Binding(get: { recipes[index].cleanup != nil }, set: { on in
                    recipes[index].cleanup = on ? { var a = ImageAdjustments(); a.scan = true; return a }() : nil }))
                Toggle("自动裁边（奇偶页分别）", isOn: $recipes[index].autoCrop)
                Toggle("OCR 识别文字", isOn: Binding(get: { recipes[index].ocr != nil }, set: { recipes[index].ocr = $0 ? OCRSettings() : nil }))
                if recipes[index].ocr != nil {
                    Picker("语言", selection: Binding(get: { recipes[index].ocr?.languages ?? [] }, set: { recipes[index].ocr?.languages = $0 })) {
                        ForEach(OCRSettings.presets) { Text($0.title).tag($0.languages) }
                    }
                    Toggle("竖排", isOn: Binding(get: { recipes[index].ocr?.vertical ?? false }, set: { recipes[index].ocr?.vertical = $0 }))
                    Toggle("忽略旧文字层，整页重新识别", isOn: Binding(get: { recipes[index].ocr?.ignoresTextLayer ?? false }, set: { recipes[index].ocr?.ignoresTextLayer = $0 }))
                }
                Toggle("输出可搜索 PDF", isOn: $recipes[index].writePDF)
                Toggle("输出 Word（横排）", isOn: Binding(get: { recipes[index].word != nil }, set: { recipes[index].word = $0 ? WordExportOptions() : nil }))
                if recipes[index].word != nil {
                    Picker("内容", selection: Binding(get: { recipes[index].word?.content ?? .both }, set: { recipes[index].word?.content = $0 })) {
                        ForEach(WordExportOptions.Content.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("套用 Word 导出窗口里的校正对照表", isOn: $recipes[index].useReplacementRules)
                }
                Toggle("再按章节拆成多个 PDF", isOn: $recipes[index].splitChapters)
                if recipes[index].splitChapters {
                    Picker("拆分到", selection: $recipes[index].chapterDepth) {
                        Text("卷 / 篇（最上层）").tag(0)
                        Text("章（含下一层）").tag(1)
                    }
                    Toggle("没有目录时，从文字里找“卷之一”“第二章”等标题", isOn: $recipes[index].detectHeadings)
                }
            }
        } else {
            Text("选一个配方，或新建一个。").foregroundStyle(.secondary)
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("选择原文件夹…") { if let url = pick() { input = url; queue.load(url) } }
                Text(input?.path ?? "未选择").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("选择输出文件夹…") { if let url = pick() { output = url } }
                Text(output?.path ?? "未选择").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func label(_ state: BatchItem.State) -> String {
        switch state {
        case .waiting: return "等待"
        case .running: return "处理中…"
        case .done(let note): return "完成 · " + note
        case .skipped(let note): return "跳过 · " + note
        case .failed(let message): return "失败 · " + message
        }
    }

    private func color(_ state: BatchItem.State) -> Color {
        switch state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}
