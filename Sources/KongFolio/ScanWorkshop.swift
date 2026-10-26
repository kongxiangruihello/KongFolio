import SwiftUI
import PDFKit

struct ScanWorkshop: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selectedOnly = true
    @State private var fraction = 0.5
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
    private var previewKey: String { "\(tab)-\(fraction)-\(rightFirst)-\(manualAngle)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描整理").font(.title2.bold())
            Picker("工具", selection: $tab) {
                Text("跨页切分").tag(0); Text("纠偏").tag(1); Text("异常页检查").tag(2)
            }.pickerStyle(.segmented).disabled(working)
            Toggle("只处理选中的 \(workspace.effectivePages.count) 页（取消为全部页）", isOn: $selectedOnly).disabled(working)
            if tab == 0 { splitControls }
            else if tab == 1 { straightenControls }
            else { inspection }
            if tab != 2 {
                HStack {
                    thumbnail(original, label: "原页（第 \(workspace.selection+1) 页）")
                    thumbnail(preview, label: tab == 0 ? "切分后的第一页" : "纠偏预览")
                }.frame(height: 270)
            }
            if working { ProgressView("正在逐页处理…") }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button(working ? "取消任务" : "关闭") { if working { cancelAction?() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                if tab == 0 {
                    Button("切分 \(pages.count) 页") {
                        do { try workspace.splitScannedPages(pages, fraction: fraction, rightFirst: rightFirst); dismiss() }
                        catch { message = error.localizedDescription }
                    }.disabled(working).buttonStyle(.borderedProminent)
                } else if tab == 1 {
                    Button(automatic ? "检测并纠偏 \(pages.count) 页" : "按预览角度纠偏 \(pages.count) 页") { straighten() }.disabled(working).buttonStyle(.borderedProminent)
                } else {
                    Button("检查 \(pages.count) 页") { inspect() }.disabled(working).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22).frame(width: 720, height: 650)
        .interactiveDismissDisabled(working)
        .onAppear {
            do {
                let document = try PDFDocument(data: workspace.pdfData()).unwrap("无法读取页面")
                let holder = PDFDocument()
                if let page = document.page(at: workspace.selection)?.copy() as? PDFPage { holder.insert(page, at: 0) }
                original = holder
            } catch { message = error.localizedDescription }
        }
        .task(id: previewKey + (original == nil ? "-empty" : "-loaded")) {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let page = original?.page(at: 0) else { return }
            do {
                let holder = PDFDocument()
                if tab == 0 { holder.insert(try ScanProcessing.halves(page, fraction: fraction, rightFirst: rightFirst)[0], at: 0) }
                else if tab == 1 { holder.insert(try ScanProcessing.straightened(page, angle: manualAngle), at: 0) }
                preview = holder
            } catch { message = error.localizedDescription }
        }
    }
    private var splitControls: some View {
        VStack(alignment: .leading) {
            HStack { Text("中缝 \(Int(fraction*100))%") ; Slider(value: $fraction, in: 0.2...0.8) }
            Toggle("右页先输出（竖排书籍）", isOn: $rightFirst)
            Text("按可见页面宽度切分；保留文字与标注。切分属于页面裁切，不用于永久删除隐私内容。操作可撤销。")
                .font(.caption).foregroundStyle(.secondary)
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
