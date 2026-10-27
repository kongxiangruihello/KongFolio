import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct TableExtractionSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var image: CGImage?
    @State private var pieces: [TablePiece] = []
    @State private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var columns = ""
    @State private var rows = ""
    @State private var table = ExtractedTable(rows: [])
    @State private var message = ""
    @State private var working = false
    @State private var worker: Task<Void, Never>?
    @State private var sourceRevision = UUID()
    @State private var pageIndex = 0
    private var x: [Double] { (try? TableExtraction.boundaries(columns, region: region.minX...region.maxX)) ?? [] }
    private var y: [Double] { (try? TableExtraction.boundaries(rows, region: region.minY...region.maxY)) ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("提取表格 · 第 \(pageIndex + 1) 页").font(.title2.bold())
            Text("在页面上拖动框选表格，再识别行列。扫描页可点击“识别扫描文字”。适合常见横排表格；合并单元格需手动整理。").font(.caption).foregroundStyle(.secondary)
            if let image {
                TableRegionPicker(image: image, region: $region, x: x, y: y).frame(height: 260)
            }
            PanelRow {
                Button("整页") { region = CGRect(x: 0, y: 0, width: 1, height: 1); invalidate() }
                Button("识别行列") { suggest() }.disabled(working || image == nil)
                Button(working ? "识别中…" : "识别扫描文字") { scan() }.disabled(working || image == nil)
                if working { ProgressView().controlSize(.small) }
            }
            TextField("列分隔位置（从左起百分比，如 25,50,75）", text: $columns).textFieldStyle(.roundedBorder)
            TextField("行分隔位置（从上起百分比，如 10,20,30）", text: $rows).textFieldStyle(.roundedBorder)
            PanelRow {
                Text("\(max(0, y.count - 1)) 行 × \(max(0, x.count - 1)) 列").font(.caption)
                Button("生成 / 重新生成单元格") { generate() }.disabled(working)
            }
            if !table.rows.isEmpty {
                Text("可直接修改以下单元格；重新生成会替换这些修改。").font(.caption)
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(table.rows.indices, id: \.self) { r in
                            GridRow {
                                Text("\(r + 1)").font(.caption).foregroundStyle(.secondary)
                                ForEach(0..<table.columns, id: \.self) { c in
                                    TextField("", text: Binding(get: { table.rows[r][c] }, set: { table.rows[r][c] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder).frame(width: 150)
                                }
                            }
                        }
                    }.padding(4)
                }.frame(height: 190)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            PanelRow {
                Button("关闭") { workspace.showTableExtraction = false }.keyboardShortcut(.cancelAction)
                Button("导出 Word…") { export("docx") }.disabled(table.rows.isEmpty || working)
                Button("导出 Markdown…") { export("md") }.disabled(table.rows.isEmpty || working)
                Button("导出 CSV…") { export("csv") }.disabled(table.rows.isEmpty || working)
            }
        }.padding(24).adaptiveSheet(width: 760, height: 850, minimumWidth: 360, flexibleHeight: true)
            .onAppear(perform: load).onDisappear { worker?.cancel() }
            .onChange(of: region) { _, _ in invalidate() }
            .onChange(of: columns) { _, _ in table = ExtractedTable(rows: []) }
            .onChange(of: rows) { _, _ in table = ExtractedTable(rows: []) }
    }
    private func invalidate() { table = ExtractedTable(rows: []); columns = ""; rows = "" }
    private func load() {
        sourceRevision = workspace.revision; pageIndex = workspace.selection
        do {
            let document = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取当前文档")
            let page = try document.page(at: pageIndex).unwrap("当前页不存在")
            let extracted = TableExtraction.pieces(page)
            let rendered = try DocumentServices.render(page, maxDimension: 1800)
            pieces = extracted; image = rendered
            message = extracted.isEmpty ? "此页没有可定位的文字层，请识别扫描文字。" : "已读取 \(extracted.count) 个字符，请框选表格。"
        } catch { message = error.localizedDescription }
    }
    private func suggest() {
        guard let image else { return }
        do {
            let result = try TableExtraction.suggest(pieces, image: image, region: region)
            columns = result.x.map { String(format: "%.2f", $0 * 100) }.joined(separator: ",")
            rows = result.y.map { String(format: "%.2f", $0 * 100) }.joined(separator: ",")
            message = "已建议分隔位置。核对蓝色网格，调整百分比后生成单元格。"
        } catch { message = error.localizedDescription }
    }
    private func scan() {
        guard let image else { return }; working = true; table = ExtractedTable(rows: [])
        let languages = workspace.ocrSettings.languages
        worker = Task {
            let job = Task.detached { try Task.checkCancellation(); return try TableExtraction.recognize(image, languages: languages) }
            do {
                let lines = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation(); pieces = lines; message = "已识别 \(lines.count) 个字符。请识别行列并核对；原 PDF 不变。"
            } catch is CancellationError {} catch { message = error.localizedDescription }
            working = false
        }
    }
    private func generate() {
        do {
            guard sourceRevision == workspace.revision else { throw FolioError(message: "文档已变化，请重新打开表格提取") }
            let xx = try TableExtraction.boundaries(columns, region: region.minX...region.maxX), yy = try TableExtraction.boundaries(rows, region: region.minY...region.maxY)
            table = try TableExtraction.extract(pieces, x: xx, y: yy); message = "请核对并修正单元格，再导出。首行在 Markdown / Word 中作为表头。"
        } catch { message = error.localizedDescription }
    }
    private func export(_ suffix: String) {
        guard sourceRevision == workspace.revision else { message = "文档已变化，请重新打开表格提取"; return }
        guard let destination = workspace.saveURL(type: UTType(filenameExtension: suffix) ?? .data, suffix: suffix, name: workspace.title + "-表格") else { return }
        do {
            if suffix == "docx" { try table.writeWord(to: destination) }
            else { try (suffix == "csv" ? table.csv : table.markdown).write(to: destination, atomically: true, encoding: .utf8) }
            message = "已导出 \(destination.lastPathComponent)"
        } catch { message = error.localizedDescription }
    }
}

private struct TableRegionPicker: View {
    var image: CGImage
    @Binding var region: CGRect
    var x: [Double]
    var y: [Double]
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: w, height: h)
                Path { path in
                    path.addRect(CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h))
                    for value in x.dropFirst().dropLast() { path.move(to: CGPoint(x: value * w, y: region.minY * h)); path.addLine(to: CGPoint(x: value * w, y: region.maxY * h)) }
                    for value in y.dropFirst().dropLast() { path.move(to: CGPoint(x: region.minX * w, y: value * h)); path.addLine(to: CGPoint(x: region.maxX * w, y: value * h)) }
                }.stroke(.blue, lineWidth: 1.5)
            }.frame(width: w, height: h).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 3).onEnded { value in
                let a = CGPoint(x: min(1, max(0, value.startLocation.x / w)), y: min(1, max(0, value.startLocation.y / h)))
                let b = CGPoint(x: min(1, max(0, value.location.x / w)), y: min(1, max(0, value.location.y / h)))
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                if rect.width > 0.02, rect.height > 0.02 { region = rect }
            }).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.gray.opacity(0.1))
    }
}
