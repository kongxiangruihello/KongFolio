import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct TableExtractionSheet: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var model: TableEditorModel
    @State private var columns = ""
    @State private var rows = ""
    @State private var pageRange = ""
    @State private var removeHeaders = false
    @State private var regionMode = false
    @State private var chosenRow = 0
    @State private var chosenColumn = 0
    init(workspace: Workspace) { self.workspace = workspace; _model = StateObject(wrappedValue: TableEditorModel(storage: workspace.storage)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("整理表格 · 第 \((model.draft?.page ?? workspace.selection) + 1) 页").font(.title2.bold())
            Text("框选表格后识别行列，拖动蓝线调整。单元格修改自动保留；重新生成会替换单元格，可撤销。").font(.caption).foregroundStyle(.secondary)
            if let image = model.image, let draft = model.draft {
                TableGridView(image: image, grid: draft.grid, regionMode: regionMode, change: model.changeGrid).frame(height: 260).disabled(model.working || model.stale)
            }
            if model.working { ProgressView(); Button("取消处理") { model.cancel() } }
            PanelRow {
                Toggle("框选范围", isOn: $regionMode).toggleStyle(.button)
                Button("整页") { model.changeGrid(TableGrid()) }
                Button("识别行列") { regionMode = false; model.suggest() }
                Button("识别扫描文字") { model.recognize(languages: workspace.ocrSettings.languages) }
                Button("撤销") { model.undo() }.disabled(model.undoStates.isEmpty)
                Button("重做") { model.redo() }.disabled(model.redoStates.isEmpty)
            }.disabled(model.working || model.stale)
            PanelRow {
                Button("加列分隔线") { addDivider(vertical: true) }
                Button("加行分隔线") { addDivider(vertical: false) }
                Button("生成 / 重新生成单元格") { model.generate() }
            }.disabled(model.working || model.stale)
            DisclosureGroup("精确调整分隔线（百分比；删除数字即可移除分隔线）") {
                TextField("列：25,50,75", text: $columns).textFieldStyle(.roundedBorder)
                TextField("行：10,20,30", text: $rows).textFieldStyle(.roundedBorder)
                Button("应用分隔位置") { applyGuides() }.disabled(model.working || model.stale)
            }
            if let draft = model.draft, !draft.rows.isEmpty {
                Text("\(draft.rows.count) 行 × \(draft.columns) 列 · \(draft.regions.count) 个来源页\(draft.needsRegeneration ? " · 分隔已变化，请重新生成" : " · 草稿已保存")").font(.caption)
                cells(draft)
                PanelRow {
                    Picker("行", selection: $chosenRow) { ForEach(draft.rows.indices, id: \.self) { Text("\($0 + 1)").tag($0) } }.frame(width: 90)
                    Button("下方插入行") { structure(.insertRow(min(chosenRow + 1, draft.rows.count))) }
                    Button("删除行") { structure(.deleteRow(chosenRow)) }
                    Picker("列", selection: $chosenColumn) { ForEach(0..<draft.columns, id: \.self) { Text("\($0 + 1)").tag($0) } }.frame(width: 90)
                    Button("右侧插入列") { structure(.insertColumn(min(chosenColumn + 1, draft.columns))) }
                    Button("删除列") { structure(.deleteColumn(chosenColumn)) }
                }.disabled(model.working)
                DisclosureGroup("合并连续页面的表格") {
                    TextField("页码，例如 3-5（从当前表格页开始）", text: $pageRange).textFieldStyle(.roundedBorder)
                    Toggle("移除后续页与首行完全相同的重复表头", isOn: $removeHeaders)
                    Text("沿用本页列位置和框选范围，后续页自动判断行；请核对合并结果及跨页断行。").font(.caption).foregroundStyle(.secondary)
                    Button("提取并合并") { merge() }.disabled(model.working || model.stale || draft.needsRegeneration)
                }
                PanelRow {
                    Button(draft.includeInWord ? "取消加入 Word 正文" : "加入 Word 正文") { model.edit { $0.includeInWord.toggle() }; model.message = "已记录。打开“导出 Word”可预览正文与表格的顺序。" }.disabled(model.working || model.stale || draft.needsRegeneration)
                    if draft.includeInWord { Text("已加入 Word 导出").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            PanelRow {
                Button("关闭") { model.cancel(); workspace.showTableExtraction = false }.keyboardShortcut(.cancelAction)
                Button("导出 Word 表格…") { export("docx") }.disabled(!canExport)
                Button("导出 Markdown…") { export("md") }.disabled(!canExport)
                Button("导出 CSV…") { export("csv") }.disabled(!canExport)
            }
        }.padding(24).adaptiveSheet(width: 800, height: 880, minimumWidth: 360, flexibleHeight: true)
            .onAppear(perform: load).onDisappear { model.cancel() }
            .onChange(of: model.draft?.grid) { _, _ in updateGuideText() }
            .onChange(of: model.draft?.rows.count) { _, n in chosenRow = min(chosenRow, max(0, (n ?? 1) - 1)) }
            .onChange(of: model.draft?.columns) { _, n in chosenColumn = min(chosenColumn, max(0, (n ?? 1) - 1)) }
            .onChange(of: workspace.revision) { _, _ in model.stale = true; model.message = "文档已变化，草稿保留供核对。请关闭后重新打开。" }
    }
    private var canExport: Bool { !model.working && model.draft?.rows.isEmpty == false && model.draft?.needsRegeneration == false }
    private func cells(_ draft: TableDraftRecord) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(draft.rows.indices, id: \.self) { r in
                    HStack(alignment: .top, spacing: 4) {
                        Button("\(r + 1)") { chosenRow = r }.buttonStyle(.plain).frame(width: 28)
                        ForEach(0..<draft.columns, id: \.self) { c in
                            TextField("", text: Binding(get: { model.draft?.rows[safe: r]?[safe: c] ?? "" }, set: { chosenRow = r; chosenColumn = c; model.setCell(row: r, column: c, text: $0) }), axis: .vertical)
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                        }
                    }
                }
            }.padding(4)
        }.frame(height: 180).disabled(model.working)
    }
    private func load() {
        model.changed = { [weak workspace] in workspace?.updateTableDraft($0) }
        let saved = workspace.tableDrafts.first(where: { $0.id == workspace.pendingTableDraftID }) ?? workspace.tableDrafts.filter { $0.page == workspace.selection }.sorted { $0.modified > $1.modified }.first
        workspace.pendingTableDraftID = nil
        do { model.open(data: try workspace.pdfData(), page: saved?.page ?? workspace.selection, identity: workspace.tableIdentity, sourcePath: (workspace.projectURL ?? workspace.sourceURL)?.path, title: workspace.displayName, saved: saved) }
        catch { model.message = error.localizedDescription }
    }
    private func updateGuideText() {
        columns = model.draft?.grid.x.dropFirst().dropLast().map { String(format: "%.2f", $0 * 100) }.joined(separator: ",") ?? ""
        rows = model.draft?.grid.y.dropFirst().dropLast().map { String(format: "%.2f", $0 * 100) }.joined(separator: ",") ?? ""
    }
    private func addDivider(vertical: Bool) {
        guard var grid = model.draft?.grid else { return }
        let values = vertical ? grid.x : grid.y
        guard let gap = zip(values, values.dropFirst()).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) else { return }
        if vertical { grid.x.append((gap.0 + gap.1) / 2); grid.x.sort() } else { grid.y.append((gap.0 + gap.1) / 2); grid.y.sort() }
        model.changeGrid(grid)
    }
    private func applyGuides() {
        guard var grid = model.draft?.grid else { return }
        do { grid.x = try TableExtraction.boundaries(columns, region: grid.region.minX...grid.region.maxX); grid.y = try TableExtraction.boundaries(rows, region: grid.region.minY...grid.region.maxY); model.changeGrid(grid) }
        catch { model.message = error.localizedDescription }
    }
    private func structure(_ action: TableCellEdit) { model.edit { $0.rows = try action.applying(to: $0.rows) } }
    private func merge() {
        guard let pages = PageSpan.parse(pageRange, pageCount: workspace.count), !pageRange.isEmpty else { model.message = "请填写连续页码"; return }
        guard let draft = model.draft, let store = workspace.store else { return }
        do { try workspace.startTableMerge(draft, pages: pages, removeHeaders: removeHeaders, queue: store.documentTasks); workspace.showTableExtraction = false }
        catch { model.message = error.localizedDescription }
    }
    private func export(_ suffix: String) {
        guard let draft = model.draft, let queue = workspace.store?.documentTasks,
              let destination = workspace.saveURL(type: UTType(filenameExtension: suffix) ?? .data, suffix: suffix, name: workspace.title + "-表格") else { return }
        do {
            let expected = try FileBaseline.capture(destination), table = ExtractedTable(rows: draft.rows)
            try queue.start("导出表格 · \(workspace.displayName)") { progress in
                try DocumentTaskOutput.write(to: destination, expected: expected) { staging in
                    if suffix == "docx" { try table.writeWord(to: staging) }
                    else { try (suffix == "csv" ? table.csv : table.markdown).write(to: staging, atomically: true, encoding: .utf8) }
                    progress(1)
                }
                return DocumentTaskResult(message: "表格已导出", file: destination)
            }
            workspace.showTableExtraction = false
        } catch { model.message = error.localizedDescription }
    }
}

private struct TableGridView: View {
    var image: CGImage
    var grid: TableGrid
    var regionMode: Bool
    var change: (TableGrid) -> Void
    @State private var moving: TableGrid?
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale, shown = moving ?? grid
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable()
                Path { path in
                    path.addRect(CGRect(x: shown.region.minX * w, y: shown.region.minY * h, width: shown.region.width * w, height: shown.region.height * h))
                    for value in shown.x.dropFirst().dropLast() { path.move(to: CGPoint(x: value * w, y: shown.region.minY * h)); path.addLine(to: CGPoint(x: value * w, y: shown.region.maxY * h)) }
                    for value in shown.y.dropFirst().dropLast() { path.move(to: CGPoint(x: shown.region.minX * w, y: value * h)); path.addLine(to: CGPoint(x: shown.region.maxX * w, y: value * h)) }
                }.stroke(.blue, lineWidth: 1.5).allowsHitTesting(false)
                if !regionMode {
                    ForEach(Array(grid.x.indices.dropFirst().dropLast()), id: \.self) { i in
                        Color.blue.opacity(0.12).frame(width: 12, height: grid.region.height * h).position(x: shown.x[i] * w, y: grid.region.midY * h)
                            .gesture(lineDrag(vertical: true, index: i, dimension: w)).help("左右拖动调整列位置")
                    }
                    ForEach(Array(grid.y.indices.dropFirst().dropLast()), id: \.self) { i in
                        Color.blue.opacity(0.12).frame(width: grid.region.width * w, height: 12).position(x: grid.region.midX * w, y: shown.y[i] * h)
                            .gesture(lineDrag(vertical: false, index: i, dimension: h)).help("上下拖动调整行位置")
                    }
                }
            }.frame(width: w, height: h).contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 3).onEnded { value in
                    guard regionMode else { return }
                    let a = CGPoint(x: min(1, max(0, value.startLocation.x / w)), y: min(1, max(0, value.startLocation.y / h))), b = CGPoint(x: min(1, max(0, value.location.x / w)), y: min(1, max(0, value.location.y / h)))
                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    if TableGrid.validRect(rect) { change(TableGrid(region: rect, x: [rect.minX, rect.maxX], y: [rect.minY, rect.maxY])) }
                }).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.gray.opacity(0.1))
    }
    private func lineDrag(vertical: Bool, index: Int, dimension: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            var next = grid
            let base = vertical ? grid.x[index] : grid.y[index], delta = (vertical ? value.translation.width : value.translation.height) / dimension
            if (try? next.move(vertical: vertical, index: index, value: base + delta)) != nil { moving = next }
        }.onEnded { _ in if let moving { change(moving) }; moving = nil }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
