import SwiftUI
import PDFKit

struct ResearchPanel: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var research: ResearchStore
    var onClose: (() -> Void)? = nil
    @StateObject private var controller = ResearchController()
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var name = ""
    @State private var includeOriginals = true
    @State private var segments = "1 5 1 无页码\n6 20 1 罗马数字\n21 100 1 数字"
    @State private var jumpLabel = ""
    @State private var journal = PeriodicalRecord()
    @State private var periodicalQuery = ""
    @State private var from = ""
    @State private var to = ""
    @State private var scope = "全局"
    @State private var filter = ResearchFilter(name: "常用筛选")
    @State private var tagText = ""
    @State private var recentDays = 0
    @State private var rightPath = ""
    @State private var editionText = "1 1 开始"
    @State private var editionName = "版本对应"
    @State private var includeAnnotations = false
    @State private var oldPage = 1
    @State private var newPage = 1
    @State private var template = CitationTemplate().text
    @State private var sampleRange = "1-3"
    @State private var recipeIndex = 0
    @State private var topicName = ""
    @State private var panelWidth: CGFloat = 1060
    private var workspace: Workspace? { store.commandWorkspace }
    private var path: String { workspace?.displayPath ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("阅读与史料研究").font(.headline); Spacer(); Text(workspace?.displayName ?? "未打开书籍").lineLimit(1); Button("关闭") { controller.flushAcademicDraft(); if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction) }
            if panelWidth < 900 { tabPicker.pickerStyle(.menu) } else { tabPicker.pickerStyle(.segmented) }
            if let warning = research.warning(path:path) { VStack(alignment:.leading) { Text(warning).foregroundStyle(.orange); HStack { Button("检查原文件") { store.checkOpenSourceChanges() }; Button("保留备份并重新载入") { if let workspace { controller.reloadSource(workspace) } }; Button("核对后确认当前关联") { if let workspace { controller.confirmSource(workspace,research:research) } } } }.disabled(controller.busy) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab { case 0: groups; case 1: labels; case 2: annotations; case 3: editions; case 4: academic; case 5: trial; default: ResearchTopicEditor(research:research,store:store,controller:controller) }
                }.padding(4)
            }
            if controller.busy { HStack { ProgressView(value:controller.progress); Text(controller.phase); Button("取消处理") { controller.cancel() } } }
            if let error = research.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(controller.message).font(.caption).textSelection(.enabled).lineLimit(8)
        }.padding(18).adaptiveSheet(width: 1060, height: 820, minimumWidth: 620)
        .background(GeometryReader { geometry in Color.clear.onAppear { panelWidth = geometry.size.width }.onChange(of:geometry.size.width) { _,width in panelWidth = width } })
        .onAppear { loadSettings(); controller.attachAcademicDraft(store) }
        .onDisappear { controller.flushAcademicDraft() }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow, window.identifier?.rawValue == "research-workbench" { controller.flushAcademicDraft(); controller.sampleOriginal = nil; controller.sampleResult = nil; controller.academicPreviewURL = nil }
        }
        .onChange(of: path) { _,_ in loadSettings(); controller.attachAcademicDraft(store) }
    }
    private var tabPicker: some View {
        Picker("功能",selection:$tab) { Text("阅读组与备份").tag(0); Text("页码与卷期").tag(1); Text("批注与校对").tag(2); Text("版本重新关联").tag(3); Text("引文与 Word").tag(4); Text("批处理试做").tag(5); Text("专题稿").tag(6) }
    }
    private func action(_ operation: () throws -> Void) { do { try operation() } catch { controller.message = error.localizedDescription } }
    private func loadSettings() {
        journal = research.periodical(path: path) ?? PeriodicalRecord(); template = research.state.citation.text
        if let values = research.state.labels[path] { segments = values.map { "\($0.start+1) \($0.end+1) \($0.first) \($0.style.rawValue) \($0.prefix)" }.joined(separator: "\n") } else { segments = "1 \(max(1,workspace?.count ?? 1)) 1 数字" }
    }
    private var groups: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存当前阅读现场").font(.headline)
            HStack { TextField("阅读组名称", text: $name); Button("保存当前阅读组") { action { try store.captureReadingGroup(name: name) } }.disabled(controller.busy) }
            ForEach(research.state.groups) { group in
                HStack { Text(group.name); Text("\(group.books.count) 本").foregroundStyle(.secondary); Spacer()
                    Button("恢复阅读") { action { try store.restoreReadingGroup(group) } }
                    Button("关闭这一组") { controller.closeGroup(store, group: group) }
                    Button("移除记录") { action { try research.update { $0.groups.removeAll { $0.id == group.id } } } }
                }
            }
            Divider(); Text("阅读资料备份与换机恢复").font(.headline)
            Toggle("连同原书一起备份（建议换机时开启）", isOn: $includeOriginals)
            HStack { Button("备份全部阅读资料…") { controller.backup(store, includeOriginals: includeOriginals) }; Button("恢复备份并载入书架…") { controller.restoreBackup(store) } }.disabled(controller.busy)
            Text("包含书签、OCR 校对、签名编辑资料、心得、链接、研究设置和阅读进度。恢复生成独立目录并合并书架；当前同名资料优先保留，缺失原件列出供重新定位。").font(.caption)
            ResearchRestorePreview(controller:controller,store:store)
            Divider(); Text("运行状态与内存").font(.headline)
            HStack { Text("实际驻留 \(store.residentMemoryMB) MB"); Text(store.constrainedMemory ? "已降低并行任务与后台加载" : "正常负载").foregroundStyle(store.constrainedMemory ? .orange : .secondary); Button("刷新状态") { store.sampleRuntimeMemory() } }
            ForEach(store.tabs.compactMap(\.workspace).filter { $0.needsLoad },id:\.id) { w in Text("已暂时释放：" + (w.displayPath.map { URL(fileURLWithPath:$0).lastPathComponent } ?? "书籍")).font(.caption) }
            if !store.startupEntries.isEmpty { Button("继续检查上次阅读现场") { store.showStartupReview = true } }
            HStack { Stepper("内存预算 \(store.memoryBudgetMB) MB", value: $store.memoryBudgetMB, in: 128...4096, step: 128); Stepper("最多加载 \(store.maxLoadedTabs) 本", value: $store.maxLoadedTabs, in: 1...24) }
            HStack { Button("整理后台内存") { store.loadedTabsChanged(); controller.message = "已请求安全释放后台文档，未保存的编辑继续保留" }; Button("查看卡顿诊断记录") { NSWorkspace.shared.activateFileViewerSelecting([store.storage.appendingPathComponent("Diagnostics")]) } }
            Text("结合实际驻留与文件估算调整负载；未保存和可见书籍继续保留，内存不会强制截断。诊断不记录正文，不自动上传。").font(.caption)
            if let workspace { Divider(); ReadingRulerControls(workspace:workspace) }
        }
    }
    private var labels: some View {
        VStack(alignment:.leading,spacing:12) {
            if let workspace { PrintedPagesEditor(workspace:workspace,research:research,controller:controller) }
            Divider(); Text("当前书籍的报刊卷期").font(.headline)
            HStack { TextField("刊名", text: $journal.journal); TextField("年份", text: $journal.year); TextField("卷", text: $journal.volume) }
            HStack { TextField("期号（数字可检查缺期）", text: $journal.issue); TextField("日期 YYYY-MM-DD", text: $journal.date); TextField("版次", text: $journal.edition) }
            Button("保存当前书籍卷期") { action { guard !path.isEmpty else { throw FolioError(message: "请打开已保存的书籍") }; try journal.validate(); try research.update { $0.periodicals[path] = journal.citation.isEmpty ? nil : journal }; controller.message = "卷期已保存" } }
            ForEach(research.periodicalProblems(), id: \.self) { Text($0).foregroundStyle(.orange) }
            TextField("筛选刊名、年份、卷期或版次", text: $periodicalQuery)
            ForEach(research.state.periodicals.keys.filter { periodicalQuery.isEmpty || (research.state.periodicals[$0]?.citation.localizedCaseInsensitiveContains(periodicalQuery) ?? false) }.sorted(by: { (research.state.periodicals[$0]?.date ?? "") < (research.state.periodicals[$1]?.date ?? "") }), id: \.self) { path in
                HStack { Text(research.state.periodicals[path]?.citation ?? ""); Spacer(); Button("打开") { store.openEach([URL(fileURLWithPath: path)]) } }
            }
            Divider(); PeriodicalBatchEditor(library:store.library,research:research,controller:controller)
        }
    }
    private var annotations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("跨书批注与保存筛选").font(.headline)
            HStack { Button("更新书架批注索引") { controller.indexAnnotations(store) }.disabled(controller.busy); TextField("筛选名称", text: $filter.name); Button("保存筛选") { action { var value = filter; value.windowDays = recentDays > 0 ? recentDays : nil; value.after = nil; try research.update { $0.filters.append(value) } } } }
            HStack { TextField("文字", text: $filter.text); TextField("类型（可留空）", text: $filter.kind); TextField("颜色（如 黄）", text: $filter.color); TextField("标签", text: $filter.tag) }
            HStack { Picker("观察到修改的时间", selection: $recentDays) { Text("不限日期").tag(0); Text("最近7天").tag(7); Text("最近30天").tag(30) }; TextField("为命中批注设置标签，逗号分隔", text: $tagText); Button("给筛选结果加标签") { action { let ids = Set(filteredAnnotations.map(\.key)); try research.update { value in for index in value.annotations.indices where ids.contains(value.annotations[index].key) { value.annotations[index].tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; value.annotations[index].modified = Date() } } } } }
            ForEach(research.state.filters) { item in Button(item.name) { filter = item; recentDays = item.windowDays ?? 0 } }
            ForEach(Array(filteredAnnotations.prefix(200))) { note in HStack(alignment: .top) { Text(URL(fileURLWithPath: note.path).lastPathComponent + " · 第\(note.page+1)页\n" + note.quote + "\n" + note.comment).lineLimit(5); Spacer(); Button("原文") { action { try store.openReadingShortcut(ReadingShortcut(path: note.path, title: "批注原文", mode: .fixed, position: ViewPosition(selection: note.page))) } } } }
            HStack { TextField("专题名称",text:$topicName); Button("将筛选结果加入专题") { addToTopic() }.disabled(filteredAnnotations.isEmpty) }
            Divider(); CorrectionDictionaryView(research:research,library:store.library,controller:controller,workspace:workspace)
        }
    }
    private func addToTopic() {
        action {
            let name = topicName.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty else { throw FolioError(message:"请填写专题名称") }
            let notes = filteredAnnotations
            try research.update { value in
                if value.topics == nil { value.topics = [] }
                if let index = value.topics?.firstIndex(where: { $0.name == name }) { value.topics![index].add(notes) }
                else { var topic = ResearchTopic(name:name); topic.add(notes); value.topics?.append(topic) }
            }
            controller.message = "已加入专题，可在“专题稿”中排序和补充论述"
        }
    }
    private var filteredAnnotations: [ResearchAnnotation] {
        var value = filter; value.windowDays = recentDays > 0 ? recentDays : nil
        return research.state.annotations.filter(value.matches)
    }
    private var editions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("原文件换版：核对后重新关联阅读资料").font(.headline)
            Button("选择新版本 PDF 并建议对应页…") { if let w = workspace { controller.prepareReassociation(w) } }.disabled(workspace == nil || controller.busy)
            HStack { Stepper("预览旧页 \(oldPage)", value: $oldPage, in: 1...max(1,controller.sampleOriginal?.pageCount ?? 1)); Stepper("预览新页 \(newPage)", value: $newPage, in: 1...max(1,controller.sampleResult?.pageCount ?? 1)) }
            HStack { ResearchPDFPreview(document: controller.sampleOriginal, page: oldPage-1); ResearchPDFPreview(document: controller.sampleResult, page: newPage-1) }.frame(height: 260)
            ForEach(controller.pairs.indices, id: \.self) { index in
                HStack { Text("旧第\(controller.pairs[index].old+1)页 →"); TextField("新页码，留空不迁移", text: Binding(get: { controller.pairs[index].proposed.map { String($0+1) } ?? "" }, set: { controller.pairs[index].proposed = Int($0).map { $0-1 } })).frame(width: 150); Text(controller.pairs[index].reason).font(.caption); Button("对照") { oldPage = controller.pairs[index].old+1; newPage = (controller.pairs[index].proposed ?? 0)+1 } }
            }
            Toggle("同时复制已确认页面的标注（页面尺寸必须相同）", isOn: $includeAnnotations)
            Text("书签与目录按确认页迁移；像素相关的 OCR 原页、校对区域、签名编辑层与草稿保留在旧资料中，不直接套用新扫描页。").font(.caption)
            Button("确认对应并生成独立文档") { controller.applyReassociation(store, includeAnnotations: includeAnnotations) }.disabled(controller.pairs.isEmpty || controller.busy)
            Divider(); if let workspace { EditionAnchorsEditor(workspace:workspace,research:research,controller:controller) }
        }
    }
    private var academic: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义史料引文").font(.headline)
            Text("可用字段：{author} {title} {periodical} {page} {quote} {link}；先在原书选中文字，再打开此面板。").font(.caption)
            TextEditor(text: $template).frame(height: 80).border(.quaternary)
            HStack { Button("保存引文模板") { action { try research.update { $0.citation.text = template } } }; Button("复制当前页引文") { action { controller.message = try workspace?.copyResearchCitation() ?? "请先打开原书" } } }
            Divider(); Text("Word 学术整理稿").font(.headline)
            Button("载入当前 PDF／文字文件正文") { controller.loadAcademic(store) }.disabled(controller.busy)
            Text("脚注：正文[^1]，另行 [^1]: 注释；尾注改用[~1]。:::caption 题注；:::page 原页码并分页。章节使用 # 标题，表格和图片沿用 Markdown。").font(.caption)
            HStack { ForEach(AcademicInsertion.allCases) { kind in Button("插入"+kind.rawValue) { controller.insertAcademic(kind) } }; Button("刷新 Word 预览") { controller.previewAcademic() }.disabled(controller.busy) }
            HSplitView {
                AcademicTextEditor(controller:controller).frame(minWidth:260)
                VStack(alignment:.leading) {
                    if let url = controller.academicPreviewURL { AcademicFilePreview(url:url) }
                    else { Text("点击“刷新 Word 预览”核对实际生成的 Word 文件").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                    if let digest = controller.academicPreviewDigest, digest != OCRPageCache.digest(Data(controller.academicText.utf8)) { Text("草稿已修改，请刷新预览").foregroundStyle(.orange) }
                }.frame(minWidth:250)
            }.frame(height:420)
            HStack { Button("检查待核文字和注释") { action { controller.academicWarnings = try AcademicMarkup.parse(controller.academicText).warnings; controller.message = controller.academicWarnings.isEmpty ? "注释完整，未发现待核标记；仍请核对识别文字" : "请处理下方待核位置" } }; Button("导出学术 Word…") { controller.exportAcademic() }.disabled(controller.busy || controller.academicText.isEmpty) }
            ForEach(controller.academicWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            if !controller.academicWarnings.isEmpty { Button("已核对，继续导出") { controller.exportAcademic(reviewed: true) }.disabled(controller.busy) }
        }
    }
    private var trial: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批处理先试做几页").font(.headline)
            let recipes = WorkRecipeStore.load()
            if !recipes.isEmpty {
                Picker("批处理配方", selection: $recipeIndex) { ForEach(recipes.indices, id: \.self) { Text(recipes[$0].name).tag($0) } }
                TextField("试做页码，例如 1-3（最多5页）", text: $sampleRange)
                Button("试做并对照") { if recipes.indices.contains(recipeIndex) { controller.trial(store, recipe: recipes[recipeIndex], range: sampleRange) } }.disabled(controller.busy)
            } else { Text("请先在文件夹批处理中保存一个配方。") }
            if let report = controller.trialReport { Text(report.summary).textSelection(.enabled); Button("将相同配方带入正式批处理…") { controller.promoteTrial(store) }.disabled(controller.busy || store.batchQueue.running) }
            if let folder = controller.trialFolder { Button("查看试做的 PDF／Word／章节文件") { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
            HStack { ResearchPDFPreview(document: controller.sampleOriginal, page: 0); ResearchPDFPreview(document: controller.sampleResult, page: 0) }.frame(height: 420)
            Text("左侧试做前，右侧试做后；不会改原件，也不会自动运行整批任务。确认效果后可关闭本面板，到文件夹批处理中应用同一配方。").font(.caption)
        }
    }
}

struct ResearchPDFPreview: NSViewRepresentable {
    var document: PDFDocument?
    var page: Int
    final class Coordinator { var lastPage: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView { let view = ManagedPDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document; context.coordinator.lastPage = nil }
        guard context.coordinator.lastPage != page else { return }
        context.coordinator.lastPage = page
        if let target = document?.page(at: max(0,min(page,(document?.pageCount ?? 1)-1))) { view.go(to: target) }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { view.clearSelection(); view.document = nil; view.delegate = nil }
}
