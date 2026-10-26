import SwiftUI
import AppKit

struct BatchSheet: View {
    @ObservedObject var workspace: Workspace
    var body: some View { TaskCenterPanel(queue:workspace.batchQueue,replacements:workspace.applyReplacements ? ReplacementRules.parse(workspace.replacementText) : []) }
}

struct TaskCenterPanel: View {
    @ObservedObject var queue: BatchQueue
    var replacements: [ReplacementRule]
    @Environment(\.dismiss) private var dismiss
    @State private var recipes = WorkRecipeStore.load()
    @State private var selected: UUID?
    @State private var output: URL?
    private var index: Int? { recipes.firstIndex { $0.id == selected } }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ScrollView {
            VStack(alignment:.leading,spacing:10) {
            HStack { Text("任务中心与扫描配方").font(.title2.bold());Spacer();Text("已完成 \(queue.completedCount)/\(queue.items.count) · 失败 \(queue.failedCount)").font(.caption) }
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading) {
                    List(selection:$selected) { ForEach(recipes) { Text($0.name).tag($0.id as UUID?) } }.frame(width:220,height:280)
                    HStack {
                        Button("新建") { let r=WorkRecipe(name:"新配方");recipes.append(r);selected=r.id }
                        Button("复制") { if let index { var r=recipes[index];r.id=UUID();r.name += " 副本";recipes.append(r);selected=r.id } }.disabled(index == nil)
                        Button("删除") { if let index { recipes.remove(at:index);selected=recipes.first?.id } }.disabled(index == nil)
                    }
                }.disabled(queue.running)
                ScrollView { editor }.frame(width:510,height:320).disabled(queue.running)
            }
            Divider()
            HStack {
                Button("添加 PDF…") { chooseFiles() }
                Button("加入文件夹…") { if let folder=pickFolder() { queue.add(BatchQueue.pdfFiles(in:folder)) } }
                Button("清空队列") { queue.clear() }.disabled(queue.items.isEmpty)
                Spacer()
                Button("输出文件夹…") { if let folder=pickFolder() { output=folder } }
            }.disabled(queue.running)
            Text(output?.path ?? "请选择输出文件夹").font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if let plan=queue.plan { Text("已保存任务：\(plan.recipe.name) → \(plan.output.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            List(queue.items) { item in
                HStack {
                    Text(item.url.lastPathComponent).lineLimit(1).help(item.url.path)
                    Spacer()
                    Text(label(item.state)).font(.caption).foregroundStyle(color(item.state)).lineLimit(2).textSelection(.enabled)
                    if case .failed = item.state { Button("重试") { queue.retryItem(item.id) }.disabled(queue.running) }
                }
            }.frame(height:170)
            ProgressView(value:queue.overallProgress)
            if queue.running { Text("当前文件 \(Int(queue.fileProgress*100))%" + (queue.stopping ? " · 正在暂停，完成当前页后停止" : "")).font(.caption) }
            if !queue.summary.isEmpty { Text(queue.summary).font(.callout).textSelection(.enabled).lineLimit(3) }
            Text("输入原件不改动，结果不会覆盖已有文件。关闭此面板后继续处理；退出应用时先暂停。队列和所用配方会保留，重启后按文件继续；当前未完成文件从头重做。").font(.caption).foregroundStyle(.secondary)
            }
            }
            HStack {
                Button("关闭面板") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出报告…") { report() }.disabled(queue.items.isEmpty)
                Spacer()
                if queue.running { Button("暂停") { queue.cancel() }.disabled(queue.stopping) }
                else {
                    Button("重试失败 \(queue.failedCount) 项") { queue.retryFailed() }.disabled(queue.failedCount == 0 || queue.plan == nil)
                    Button("继续上次任务") { queue.resume() }.disabled(queue.plan == nil)
                    Button("按当前配方开始") { if let index, let output { queue.start(recipe:recipes[index],output:output,replacements:replacements) } }
                        .disabled(index == nil || output == nil || queue.items.isEmpty).buttonStyle(.borderedProminent)
                }
            }
        }.padding(20).frame(width:820,height:740)
        .onAppear {
            if let plan=queue.plan, !recipes.contains(where: { $0.id == plan.recipe.id }) { recipes.append(plan.recipe) }
            selected=queue.plan?.recipe.id ?? recipes.first?.id;output=queue.plan?.output
        }
        .onChange(of:recipes) { _, value in WorkRecipeStore.save(value) }
        .dropDestination(for:URL.self) { urls,_ in guard !queue.running else { return false };queue.add(urls);return true }
    }
    @ViewBuilder private var editor: some View {
        if let index {
            VStack(alignment:.leading,spacing:8) {
                TextField("配方名称",text:$recipes[index].name)
                Text(recipes[index].summary).font(.caption).foregroundStyle(.secondary)
                TextField("原文件页码（如 3-400；空为全部）",text:$recipes[index].pageRange)
                Toggle("跨页扫描切分",isOn:$recipes[index].splitSpreads)
                if recipes[index].splitSpreads {
                    HStack { Text("中缝 \(Int(recipes[index].splitFraction*100))%");Slider(value:$recipes[index].splitFraction,in:0.2...0.8) }
                    Toggle("右页先输出（竖排书籍）",isOn:$recipes[index].rightPageFirst)
                }
                Toggle("自动纠偏（证据不足时跳过）",isOn:$recipes[index].autoStraighten)
                Toggle("自动裁边（奇偶页分别）",isOn:$recipes[index].autoCrop)
                Toggle("OCR 识别文字",isOn:Binding(get:{recipes[index].ocr != nil},set:{recipes[index].ocr=$0 ? OCRSettings() : nil}))
                if recipes[index].ocr != nil {
                    Picker("语言",selection:Binding(get:{recipes[index].ocr?.languages ?? []},set:{recipes[index].ocr?.languages=$0})) { ForEach(OCRSettings.presets) { Text($0.title).tag($0.languages) } }
                    Toggle("竖排",isOn:Binding(get:{recipes[index].ocr?.vertical ?? false},set:{recipes[index].ocr?.vertical=$0}))
                    Toggle("忽略已有文字层重新识别",isOn:Binding(get:{recipes[index].ocr?.ignoresTextLayer ?? false},set:{recipes[index].ocr?.ignoresTextLayer=$0}))
                }
                Toggle("压缩图片（保护带标注页）",isOn:Binding(get:{recipes[index].compress != nil},set:{recipes[index].compress=$0 ? .standard : nil}))
                if recipes[index].compress != nil {
                    Picker("压缩程度",selection:Binding(get:{recipes[index].compress ?? .standard},set:{recipes[index].compress=$0})) { ForEach(CompressLevel.allCases) { Text($0.rawValue).tag($0) } }
                }
                Toggle("输出 PDF",isOn:$recipes[index].writePDF)
                Toggle("输出 Word",isOn:Binding(get:{recipes[index].word != nil},set:{recipes[index].word=$0 ? WordExportOptions() : nil}))
                if recipes[index].word != nil {
                    Picker("Word 内容",selection:Binding(get:{recipes[index].word?.content ?? .both},set:{recipes[index].word?.content=$0})) { ForEach(WordExportOptions.Content.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("使用文字替换规则",isOn:$recipes[index].useReplacementRules)
                }
                Toggle("按章节拆分输出",isOn:$recipes[index].splitChapters)
                if recipes[index].splitChapters {
                    Picker("层级",selection:$recipes[index].chapterDepth) { Text("卷 / 篇").tag(0);Text("章").tag(1) }
                    Toggle("没有目录时检测标题",isOn:$recipes[index].detectHeadings)
                }
                Text("执行顺序固定：原页范围 → 切分 → 纠偏 → 裁边 → OCR → 压缩 → 输出。纠偏/OCR 会固化已有批注；需要保留的原件始终不改动。").font(.caption).foregroundStyle(.secondary)
            }
        } else { Text("选择或新建一个配方") }
    }
    private func chooseFiles() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.pdf];panel.allowsMultipleSelection=true
        if panel.runModal() == .OK { queue.add(panel.urls) }
    }
    private func pickFolder() -> URL? {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func report() {
        let panel=NSSavePanel();panel.nameFieldStringValue="KongFolio-处理报告.txt";panel.allowedContentTypes=[.plainText]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let text="KongFolio 任务报告\n" + (queue.plan.map { "配方：\($0.recipe.name)\n步骤：\($0.recipe.summary)\n输出：\($0.output.path)\n\n" } ?? "") + queue.items.map { "\($0.url.path)\n\(label($0.state)) · 尝试 \($0.attempts) 次" }.joined(separator:"\n\n")
        do { try text.write(to:url,atomically:true,encoding:.utf8) } catch { queue.summary="报告导出失败：\(error.localizedDescription)" }
    }
    private func label(_ state:BatchItem.State) -> String {
        switch state { case .waiting:return "等待 / 已暂停";case .running:return "处理中";case .done(let s):return "完成 · "+s;case .skipped(let s):return "跳过 · "+s;case .failed(let s):return "失败 · "+s }
    }
    private func color(_ state:BatchItem.State) -> Color {
        switch state { case .failed:return .red;case .done:return .green;default:return .secondary }
    }
}
