import SwiftUI
import AppKit

struct FolderSearchView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var model: FolderSearchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var showIssues = false
    @State private var collapsed: Set<String> = []
    private var occupied: Bool { model.running || model.openingID != nil }
    private var chosen: [FolderSearchHit] { model.visibleResults.filter { selected.contains($0.id) } }
    private var paths: [String] { Array(Set(model.visibleResults.map { $0.url.path })).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("跨文件全文搜索").font(.title2.bold())
            searchControls
            filterControls
            PanelRow {
                Text("已检查 \(model.scanned) / \(model.total) 份资料 · 显示 \(model.visibleResults.count) / \(model.results.count) 处匹配 · 选中 \(chosen.count) 处").font(.caption.monospacedDigit())
                Spacer()
                if occupied { ProgressView().controlSize(.small) }
            }
            if !model.progressText.isEmpty { Text(model.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            resultList
            issues
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled).lineLimit(3) }
            Text("附加词按同一物理页筛选，多个词用逗号分隔。⌘ 点选或 ⇧ 连选结果后可摘录；导出报告采用当前筛选。扫描件请先 OCR；笔记可切换正文或源码搜索；当前编辑含未保存内容，无须选择文件夹；批注和摘录单独标明。索引仅保存在本机。").font(.caption).foregroundStyle(.secondary)
            actions
        }.padding(20).adaptiveSheet(width: 1000, height: 760, minimumWidth: 360)
        .onDisappear { model.cancel(); model.remember() }
        .onChange(of: model.searchedQuery) { _, _ in selected = [] }
    }
    private var searchControls: some View {
        VStack(spacing: 8) {
            Picker("搜索范围", selection: $model.scope) { ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) } }.disabled(occupied)
            if model.scope.usesFolder { PanelRow {
                Button("选择并记住文件夹…") { chooseFolder() }
                Menu("常用文件夹（\(model.savedFolders.count)）") {
                    ForEach(model.savedFolders, id: \.path) { folder in
                        Button(folder.path) { model.folder = folder; model.remember() }
                    }
                    if let folder = model.folder, model.savedFolders.contains(folder) {
                        Divider(); Button("移除当前常用记录") { model.forgetFolder(folder) }
                    }
                }.disabled(model.savedFolders.isEmpty)
                Text(model.folder?.path ?? "请选择存放资料的文件夹").font(.caption).lineLimit(1).truncationMode(.middle).help(model.folder?.path ?? "")
                Spacer(); Toggle("含子文件夹", isOn: $model.recursive)
            }.disabled(occupied) }
            PanelRow {
                Toggle("文本文件", isOn: $model.includeText)
                Toggle("批注", isOn: $model.includeAnnotations)
                Toggle("笔记只搜正文", isOn: $model.bodyOnly)
            }.disabled(occupied)
            PanelRow {
                TextField("主要搜索词句（简繁通查）", text: $model.query).onSubmit { start() }.disabled(occupied)
                if model.running { Button(model.stopping ? "正在停止…" : "停止") { model.cancel() }.disabled(model.stopping) }
                else { Button("搜索") { start() }.disabled((model.scope.usesFolder && model.folder == nil) || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || occupied).buttonStyle(.borderedProminent) }
            }
            PanelRow {
                TextField("同页还需包含：词一，词二", text: $model.requiredTerms)
                TextField("同页排除：词一，词二", text: $model.excludedTerms)
            }.disabled(occupied)
        }
    }
    private var filterControls: some View {
        PanelRow {
            TextField("按文件名或相对路径筛选", text: $model.fileFilter)
            TextField("物理页码：1-20, 35", text: $model.pageFilter).frame(width: 190)
            Toggle("按文件折叠", isOn: $model.grouped)
            Button("全选筛选结果") { selected = Set(model.visibleResults.map(\.id)) }
            if model.pageFilterInvalid { Text("页码格式无效").font(.caption).foregroundStyle(.red) }
        }.disabled(occupied)
    }
    private var resultList: some View {
        List(selection: $selected) {
            if model.grouped {
                ForEach(paths, id: \.self) { path in
                    let values = model.visibleResults.filter { $0.url.path == path }
                    DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(path) }, set: { if $0 { collapsed.remove(path) } else { collapsed.insert(path) } })) {
                        ForEach(values) { result in row(result) }
                    } label: { Text((values.first?.relativePath ?? path) + "（\(values.count) 处）").font(.headline) }
                }
            } else { ForEach(model.visibleResults) { result in row(result) } }
        }.listStyle(.inset)
    }
    private func row(_ result: FolderSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.url.lastPathComponent).font(.headline)
                Text(result.category).font(.caption).foregroundStyle(.blue)
                Text((result.textLine.map { "第 \($0) 行" } ?? "第 \(result.hit.page + 1) 页") + (result.hit.label.map { " · 印刷页码 \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Text(result.hit.snippet).lineLimit(3)
            Text(result.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(result.url.path)
        }.padding(.vertical, 4).tag(result.id).onTapGesture(count: 2) { open(result) }
        .contextMenu {
            Button("打开并定位") { open(result) }.disabled(occupied)
            Button("摘录到工作区") { selected = [result.id]; excerpt([result]) }.disabled(occupied)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
        }
    }
    private var issues: some View {
        VStack(alignment: .leading) {
            if !model.noTextFiles.isEmpty || !model.problems.isEmpty {
                PanelRow {
                    Button("无文字 \(model.noTextFiles.count) 份 · 提示 \(model.problems.count) 项") { showIssues.toggle() }
                    Button("无文字 PDF 加入 OCR 任务…") { store.batchQueue.add(model.noTextFiles); store.showOCRTasksAfterSearch = true; dismiss() }.disabled(model.noTextFiles.isEmpty || occupied || store.batchQueue.running)
                }
                if showIssues { ScrollView { Text((model.noTextFiles.map { $0.path + "：未提取到文字，可先 OCR" } + model.problems).joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70) }
            }
        }
    }
    private var actions: some View {
        PanelRow {
            Button("关闭") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            Button("清除文字索引") { model.clearIndex() }.disabled(occupied)
            Button("导出结果…") { export() }.disabled(occupied || model.searchedQuery.isEmpty)
            Spacer()
            Button("摘录选中结果（\(chosen.count)）") { excerpt(chosen) }.disabled(chosen.isEmpty || occupied)
            Button("打开并定位") { if let result = chosen.first { open(result) } }.disabled(chosen.count != 1 || occupied).buttonStyle(.borderedProminent)
        }
    }
    private func start() {
        selected = []
        do { model.start(live: model.includeLive ? try store.searchSnapshots() : []) }
        catch { model.message = error.localizedDescription }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let folder = panel.url { model.keepFolder(folder) }
    }
    private func open(_ result: FolderSearchHit) { guard !occupied else { return }; Task { if await model.open(result, in: store) { dismiss() } } }
    private func excerpt(_ values: [FolderSearchHit]) { Task { if await model.excerpt(values, in: store) { dismiss() } } }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "KongFolio-搜索结果.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.report().write(to: url, atomically: true, encoding: .utf8) } catch { model.message = "导出失败：" + error.localizedDescription }
    }
}
