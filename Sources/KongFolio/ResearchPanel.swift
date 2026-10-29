import SwiftUI
import PDFKit

struct ResearchPanel: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var research: ResearchStore
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
    private var workspace: Workspace? { store.commandWorkspace }
    private var path: String { workspace?.displayPath ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("阅读与史料研究").font(.headline); Spacer(); Text(workspace?.displayName ?? "未打开书籍").lineLimit(1); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            Picker("功能", selection: $tab) {
                Text("阅读组与备份").tag(0); Text("页码与卷期").tag(1); Text("批注与校对").tag(2); Text("版本重新关联").tag(3); Text("引文与 Word").tag(4); Text("批处理试做").tag(5)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab { case 0: groups; case 1: labels; case 2: annotations; case 3: editions; case 4: academic; default: trial }
                }.padding(4)
            }
            if controller.busy { ProgressView("正在处理，可继续等待…") }
            if let error = research.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(controller.message).font(.caption).textSelection(.enabled).lineLimit(8)
        }.padding(18).adaptiveSheet(width: 1060, height: 820, minimumWidth: 620)
        .onAppear { loadSettings(); controller.attachAcademicDraft(store) }
        .onDisappear { controller.flushAcademicDraft() }
        .onChange(of: path) { _,_ in loadSettings(); controller.attachAcademicDraft(store) }
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
            Divider(); Text("运行状态与内存").font(.headline)
            HStack { Stepper("内存预算 \(store.memoryBudgetMB) MB", value: $store.memoryBudgetMB, in: 128...4096, step: 128); Stepper("最多加载 \(store.maxLoadedTabs) 本", value: $store.maxLoadedTabs, in: 1...24) }
            HStack { Button("整理后台内存") { store.loadedTabsChanged(); controller.message = "已请求安全释放后台文档，未保存的编辑继续保留" }; Button("查看卡顿诊断记录") { NSWorkspace.shared.activateFileViewerSelecting([store.storage.appendingPathComponent("Diagnostics")]) } }
            Text("内存预算根据文件、页数与撤销快照估算；系统内存紧张时额外收紧。卡顿诊断只记录阶段与用量，不记录正文或自动上传。").font(.caption)
        }
    }
    private var labels: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("印刷页码对应").font(.headline)
            Text("每行：PDF起页 PDF末页 起始号码 样式 可选前缀。页码从 1 开始；样式为 数字／罗马数字／无页码。各段不能重叠。").font(.caption)
            TextEditor(text: $segments).frame(height: 105).border(.quaternary)
            HStack { Button("保存页码对应") { saveSegments() }.disabled(workspace == nil || path.isEmpty); TextField("印刷页码，如 iv、12", text: $jumpLabel); Button("按印刷页码跳转") { if let w = workspace, let page = research.page(path: path, label: jumpLabel, count: w.count) { w.selectPage(page) } else { controller.message = "未找到对应页码" } } }
            Divider(); Text("当前书籍的报刊卷期").font(.headline)
            HStack { TextField("刊名", text: $journal.journal); TextField("年份", text: $journal.year); TextField("卷", text: $journal.volume) }
            HStack { TextField("期号（数字可检查缺期）", text: $journal.issue); TextField("日期 YYYY-MM-DD", text: $journal.date); TextField("版次", text: $journal.edition) }
            Button("保存当前书籍卷期") { action { guard !path.isEmpty else { throw FolioError(message: "请打开已保存的书籍") }; try journal.validate(); try research.update { $0.periodicals[path] = journal.citation.isEmpty ? nil : journal }; controller.message = "卷期已保存" } }
            ForEach(research.periodicalProblems(), id: \.self) { Text($0).foregroundStyle(.orange) }
            TextField("筛选刊名、年份、卷期或版次", text: $periodicalQuery)
            ForEach(research.state.periodicals.keys.filter { periodicalQuery.isEmpty || (research.state.periodicals[$0]?.citation.localizedCaseInsensitiveContains(periodicalQuery) ?? false) }.sorted(by: { (research.state.periodicals[$0]?.date ?? "") < (research.state.periodicals[$1]?.date ?? "") }), id: \.self) { path in
                HStack { Text(research.state.periodicals[path]?.citation ?? ""); Spacer(); Button("打开") { store.openEach([URL(fileURLWithPath: path)]) } }
            }
        }
    }
    private func saveSegments() {
        action {
            guard let w = workspace else { return }
            let parsed = try segments.split(separator: "\n").map { line -> PrintedPageSegment in
                let cells = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard cells.count >= 4, let start = Int(cells[0]), let end = Int(cells[1]), let first = Int(cells[2]), let style = PrintedPageSegment.Style(rawValue: cells[3]) else { throw FolioError(message: "页码格式无效：" + line) }
                return PrintedPageSegment(start: start-1, end: end-1, first: first, prefix: cells.dropFirst(4).joined(separator: " "), style: style)
            }
            try PrintedPageSegment.validate(parsed, count: w.count); try research.update { $0.labels[path] = parsed; if $0.identities == nil { $0.identities = [:] }; $0.identities?[path] = w.fileBaseline?.digest }; controller.message = "页码对应已保存"
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
            Divider(); Text("分书／分项目 OCR 校对词典").font(.headline)
            HStack { TextField("误识文字", text: $from); TextField("改为", text: $to); TextField("范围：全局、完整书籍路径或书架分类名", text: $scope) }
            Button("保存规则") { action { guard !from.isEmpty, from != to else { throw FolioError(message: "请输入不同的原文字和替换文字") }; try research.update { $0.dictionary.append(ScopedCorrection(from: from, to: to, scope: scope)) } } }
            ForEach(research.state.dictionary) { rule in HStack { Text(rule.from + " → " + rule.to + "（" + rule.scope + "）"); Spacer(); Button(rule.enabled ? "停用" : "启用") { action { try research.update { value in if let i = value.dictionary.firstIndex(where: { $0.id == rule.id }) { value.dictionary[i].enabled.toggle() } } } } } }
            HStack { Button("预览当前书籍命中") { controller.previewCorrections(store) }; Button("应用预览中的校正") { if let w = workspace, let revision = controller.correctionRevision { w.applyOCRBatch(controller.correctionHits, expected: revision); controller.message = "已发起校正；可用撤销回退" } }.disabled(controller.correctionHits.isEmpty) }
            ForEach(Array(controller.correctionHits.prefix(100))) { hit in Text("第\(hit.page+1)页：" + hit.markedContext + " → " + hit.to).font(.caption) }
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
            Divider(); Text("长期版本对照表与同步翻页").font(.headline)
            HStack { TextField("对应表名称", text: $editionName); TextField("另一个版本路径", text: $rightPath); Button("选择…") { rightPath = controller.chooseFile(pdfOnly: true)?.path ?? rightPath } }
            Text("每行：当前版本页码 对照版本页码 可选章节名；以下页码从1开始。锚点之间按页差同步。").font(.caption)
            TextEditor(text: $editionText).frame(height: 90).border(.quaternary)
            Button("保存版本对应表") { saveEdition() }
            ForEach(research.state.editions) { edition in HStack { Text(edition.name); Spacer(); Button("并排对照并同步") { workspace?.applyResearchEdition(edition) } } }
        }
    }
    private func saveEdition() {
        action {
            guard !path.isEmpty, !rightPath.isEmpty else { throw FolioError(message: "请选择当前书籍和另一版本") }
            let pairs = try editionText.split(separator: "\n").map { line -> EditionCorrespondence.Pair in let cells = line.split(whereSeparator: \.isWhitespace); guard cells.count >= 2, let a = Int(cells[0]), let b = Int(cells[1]), a > 0, b > 0 else { throw FolioError(message: "对应页码无效") }; return EditionCorrespondence.Pair(left: a-1, right: b-1, title: cells.dropFirst(2).joined(separator: " ")) }
            guard !pairs.isEmpty, Set(pairs.map(\.left)).count == pairs.count, Set(pairs.map(\.right)).count == pairs.count else { throw FolioError(message: "对应页重复或为空") }
            let edition = EditionCorrespondence(name: editionName, leftPath: path, rightPath: rightPath, pairs: pairs), leftCount = workspace?.count ?? 0
            let target = research
            controller.perform {
                let right = URL(fileURLWithPath: edition.rightPath)
                try await CloudFilePreparation.prepare([right]) { _ in }
                try await Task.detached {
                    let document = try PDFDocument(data: Data(contentsOf: right)).unwrap("对照版本无法读取")
                    try edition.validate(leftCount: leftCount, rightCount: document.pageCount)
                }.value
                try target.update { $0.editions.append(edition) }
                return "版本对应表已保存，可双向同步翻页"
            }
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
            TextEditor(text: $controller.academicText).frame(minHeight: 300).border(.quaternary)
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
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document; context.coordinator.lastPage = nil }
        guard context.coordinator.lastPage != page else { return }
        context.coordinator.lastPage = page
        if let target = document?.page(at: max(0,min(page,(document?.pageCount ?? 1)-1))) { view.go(to: target) }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { view.clearSelection(); view.document = nil; view.delegate = nil }
}
