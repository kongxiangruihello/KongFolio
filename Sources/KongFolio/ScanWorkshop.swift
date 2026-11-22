import SwiftUI
import PDFKit

struct ScanWorkshop: View {
    @ObservedObject var workspace: Workspace
    var splitOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selectedOnly = true
    @State private var fraction = 0.5
    @State private var automaticSplit = false
    @State private var gutterResult: GutterResult?
    @State private var gutterOverrides: [Int: Double] = [:]
    @State private var reviewedPage: Int?
    @State private var rightFirst = false
    @State private var manualAngle = 0.0
    @State private var automatic = true
    @State private var original: PDFDocument?
    @State private var preview: PDFDocument?
    @State private var issues: [ScanIssue] = []
    @State private var checked = false
    @State private var working = false
    @State private var message = ""
    @State private var cancelAction: (() -> Void)?
    private var pages: [Int] { selectedOnly ? workspace.effectivePages : Array(0..<workspace.count) }
    private var splitPreviewPage: Int? {
        if let reviewedPage, pages.contains(reviewedPage) { return reviewedPage }
        return pages.contains(workspace.selection) ? workspace.selection : pages.first
    }
    private var previewKey: String { "\(tab)-\(manualAngle)" }

    private struct GutterRequest: Equatable {
        let revision: UUID
        let pages: [Int]
    }

    private struct GutterResult {
        let request: GutterRequest
        let fractions: [Int: Double]
        var error: String? = nil
    }

    private var gutterRequest: GutterRequest? {
        guard tab == 0, automaticSplit, !pages.isEmpty else { return nil }
        return GutterRequest(revision: workspace.revision, pages: pages)
    }

    private var activeGutters: GutterResult? {
        guard let gutterResult, gutterResult.request == gutterRequest else { return nil }
        return gutterResult
    }

    private func splitFraction(for index: Int) -> Binding<Double> {
        guard automaticSplit else { return $fraction }
        return Binding(
            get: { gutterOverrides[index] ?? activeGutters?.fractions[index] ?? 0.5 },
            set: { gutterOverrides[index] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(splitOnly ? "拆分页面" : "扫描整理").font(.title2.bold())
            if !splitOnly {
                Picker("工具", selection: $tab) {
                    Text("跨页切分").tag(0); Text("纠偏").tag(1); Text("异常页检查").tag(2)
                }.pickerStyle(.segmented).disabled(working)
            }
            Toggle("只处理选中的 \(workspace.effectivePages.count) 页（取消为全部页）", isOn: $selectedOnly).disabled(working)
            if tab == 0 { splitControls }
            else if tab == 1 { straightenControls }
            else { inspection }
            if tab == 0, let pageIndex = splitPreviewPage, let page = workspace.document.page(at: pageIndex) {
                VStack(spacing: 7) {
                    splitPreviewNavigation(for: pageIndex)
                    SplitPagePreview(page: page,
                                     firstOutputPage: ScanProcessing.firstOutputPage(for: pageIndex, splitting: pages),
                                     rightFirst: rightFirst, fraction: splitFraction(for: pageIndex))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 395)
            } else if tab == 1 {
                HStack {
                    thumbnail(original, label: "原页（第 \(workspace.selection + 1) 页）")
                    thumbnail(preview, label: "纠偏预览")
                }.frame(height: 270)
            }
            if working { ProgressView("正在逐页处理…") }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button(working ? "取消任务" : "关闭") { if working { cancelAction?() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                if tab == 0 {
                    Button("拆分 \(pages.count) 页") {
                        do {
                            let perPage = automaticSplit
                                ? (activeGutters?.fractions ?? [:]).merging(gutterOverrides) { _, edited in edited }
                                : [:]
                            try workspace.splitScannedPages(pages, fraction: automaticSplit ? 0.5 : fraction,
                                                            rightFirst: rightFirst, pageFractions: perPage)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(working || pages.isEmpty || (automaticSplit && activeGutters == nil))
                    .buttonStyle(.borderedProminent)
                } else if tab == 1 {
                    Button(automatic ? "检测并纠偏 \(pages.count) 页" : "按预览角度纠偏 \(pages.count) 页") { straighten() }.disabled(working).buttonStyle(.borderedProminent)
                } else {
                    Button("检查 \(pages.count) 页") { inspect() }.disabled(working).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22).adaptiveSheet(width: 720, height: 680, minimumWidth: 430)
        .interactiveDismissDisabled(working)
        .task(id: gutterRequest) {
            gutterOverrides = [:]
            guard let request = gutterRequest else { return }
            do {
                let data = try workspace.pdfData()
                let analysis = Task.detached(priority: .userInitiated) { try SpreadGutter.detect(data, pages: request.pages) }
                let detected = try await withTaskCancellationHandler {
                    try await analysis.value
                } onCancel: {
                    analysis.cancel()
                }
                guard !Task.isCancelled, gutterRequest == request else { return }
                gutterResult = GutterResult(request: request, fractions: detected)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, gutterRequest == request else { return }
                gutterResult = GutterResult(request: request, fractions: [:], error: error.localizedDescription)
            }
        }
        .task(id: tab) {
            guard tab == 1, original == nil else { return }
            do {
                let document = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取页面")
                let holder = PDFDocument()
                if let page = document.page(at: workspace.selection)?.copy() as? PDFPage { holder.insert(page, at: 0) }
                original = holder
            } catch { message = error.localizedDescription }
        }
        .task(id: previewKey + (original == nil ? "-empty" : "-loaded")) {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard tab == 1, let page = original?.page(at: 0) else { return }
            do {
                let holder = PDFDocument()
                holder.insert(try ScanProcessing.straightened(page, angle: manualAngle), at: 0)
                preview = holder
            } catch { message = error.localizedDescription }
        }
    }
    private func splitPreviewNavigation(for page: Int) -> some View {
        let targets = pages
        let index = targets.firstIndex(of: page) ?? 0
        return HStack(spacing: 10) {
            Button {
                reviewedPage = targets[index - 1]
            } label: { AppIcon("chevron.left") }
                .disabled(index == 0)
                .accessibilityLabel("上一张预览")
            Text("原文档第 \(page + 1) 页")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button {
                reviewedPage = targets[index + 1]
            } label: { AppIcon("chevron.right") }
                .disabled(index >= targets.count - 1)
                .accessibilityLabel("下一张预览")
        }
        .buttonStyle(.borderless)
    }

    private var splitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("拆分方式", selection: $automaticSplit) {
                Text("手动").tag(false)
                Text("自动").tag(true)
            }
            .pickerStyle(.segmented)
            if let page = splitPreviewPage {
                let position = splitFraction(for: page)
                HStack {
                    Text("分割线 \(Int((position.wrappedValue * 100).rounded()))%").monospacedDigit()
                    Slider(value: position, in: ScanProcessing.splitFractionRange)
                        .accessibilityLabel("分割线位置")
                }
            }
            Toggle("右页先输出（竖排书籍）", isOn: $rightFirst)
            if automaticSplit {
                if let result = activeGutters {
                    let fallback = result.request.pages.count - result.fractions.count
                    if let error = result.error {
                        Text("\(error) 可以按中线拆分或拖动调整。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("检测到 \(result.fractions.count) 页中缝 · \(fallback) 页使用中线。拖动虚线可微调预览页。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("正在检测中缝…").controlSize(.small)
                }
            } else {
                Text("拖动虚线调整位置。手动分割线用于所选范围内的各页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(working)
    }

    private var straightenControls: some View {
        VStack(alignment: .leading) {
            Toggle("自动检测每页文字倾斜（最多 ±7.5°）", isOn: $automatic)
            HStack {
                Text(String(format: "预览/手动角度 %.1f°", manualAngle))
                Slider(value: $manualAngle, in: -7.5...7.5, step: 0.1)
                Button("检测当前页") { detectCurrent() }
            }
            Text("纠偏会扩展页边以保留四角，保留 PDF 文字；已有标注固化到页面，OCR 坐标记录清除。原页可撤销恢复。自动模式逐页检测，证据不足时跳过；竖排或复杂版面可手动调整。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(working)
    }
    private var inspection: some View {
        VStack(alignment: .leading) {
            Text("检查疑似空白、横向页、文字层过少和轻微倾斜。结果只是提示，不会自动删除或旋转页面。")
                .font(.caption).foregroundStyle(.secondary)
            List(issues) { issue in
                HStack {
                    VStack(alignment: .leading) { Text("第 \(issue.page+1) 页").bold(); Text(issue.reasons.joined(separator: "；")).font(.caption) }
                    Spacer()
                    Button("定位") { workspace.selectPage(issue.page); dismiss() }
                    Button("OCR 此页") { workspace.selectPage(issue.page); dismiss(); workspace.ocr(selectedOnly: true) }
                }
            }
            if checked { Text("检查完成，共 \(issues.count) 个页面需要核对。").font(.caption) }
        }.frame(maxHeight: .infinity)
    }
    private func thumbnail(_ doc: PDFDocument?, label: String) -> some View {
        VStack {
            Text(label).font(.caption)
            if let page = doc?.page(at: 0) {
                Image(nsImage: page.thumbnail(of: NSSize(width: 320, height: 240), for: .cropBox)).resizable().scaledToFit()
            } else { Color.secondary.opacity(0.08) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func inspect() {
        do {
            let data = try workspace.pdfData(), chosen = pages
            working = true; workspace.busy = true; message = ""
            let worker = Task.detached { try ScanProcessing.inspect(data, pages: chosen) }
            cancelAction = { worker.cancel() }; workspace.cancelAuxiliary = cancelAction
            Task { @MainActor in
                defer { working = false; workspace.busy = false; workspace.cancelAuxiliary = nil; cancelAction = nil }
                do { issues = try await worker.value; checked = true }
                catch is CancellationError { message = "已取消检查，文档未改动" }
                catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
    private func detectCurrent() {
        guard let data = original?.dataRepresentation() else { return }
        working = true; workspace.busy = true
        let worker = Task.detached { () throws -> Double in
            let doc = try PDFDocument(data: data).unwrap("无法读取页面")
            return try ScanProcessing.angle(doc.page(at: 0).unwrap("无法读取页面"))
        }
        cancelAction = { worker.cancel() }; workspace.cancelAuxiliary = cancelAction
        Task { @MainActor in
            defer { working = false; workspace.busy = false; workspace.cancelAuxiliary = nil; cancelAction = nil }
            do { let angle = try await worker.value; manualAngle = angle; message = angle == 0 ? "未检测到可靠倾斜，可手动调整预览角度" : String(format: "当前页检测角度 %.1f°", angle) }
            catch { message = error.localizedDescription }
        }
    }
    private func straighten() {
        do {
            let data = try workspace.pdfData(), chosen = pages, auto = automatic, angle = manualAngle
            let revision = workspace.revision
            working = true; workspace.busy = true; message = ""
            let worker = Task.detached { () throws -> (Data, Set<Int>) in
                let doc = try PDFDocument(data: data).unwrap("无法读取页面")
                var changed = Set<Int>()
                for index in chosen {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let page = try doc.page(at: index).unwrap("无法读取页面")
                        let correction = auto ? try ScanProcessing.angle(page) : angle
                        guard abs(correction) >= 0.15 else { return }
                        let result = try ScanProcessing.straightened(page, angle: correction)
                        doc.removePage(at: index); doc.insert(result, at: index); changed.insert(index)
                    }
                }
                try Task.checkCancellation()
                return (try doc.dataRepresentation().unwrap("无法保存纠偏结果"), changed)
            }
            cancelAction = { worker.cancel() }; workspace.cancelAuxiliary = cancelAction
            Task { @MainActor in
                defer { working = false; workspace.busy = false; workspace.cancelAuxiliary = nil; cancelAction = nil }
                do {
                    let result = try await worker.value
                    guard workspace.revision == revision else { message = "文档已变化，请重新执行"; return }
                    guard !result.1.isEmpty else { message = "没有可靠倾斜需要处理，文档未改动"; return }
                    try workspace.applyStraightened(result.0, pages: result.1)
                    dismiss()
                } catch is CancellationError { message = "已取消纠偏，文档未改动" }
                catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}
