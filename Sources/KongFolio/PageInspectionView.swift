import SwiftUI
import PDFKit

struct PageInspectionView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [PageInspectionCandidate] = []
    @State private var selected: Set<Int> = []
    @State private var focused: Int?
    @State private var snapshot: Data?
    @State private var document: PDFDocument?
    @State private var worker: Task<[PageInspectionCandidate], Error>?
    @State private var working = false
    @State private var message = ""
    private var candidate: PageInspectionCandidate? { candidates.first { $0.page == focused } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("空白页与重复页检查").font(.title2.bold()); Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("重新检查") { scan() }.disabled(working)
            }
            HStack {
                Button("勾选疑似空白") { selected = Set(candidates.filter { $0.kind == .blank }.map(\.page)) }
                Button("勾选重复副本") { selected = Set(candidates.filter { $0.kind == .duplicate }.map(\.page)) }
                Button("清空勾选") { selected = [] }
                Spacer(); Text("待删除 \(selected.count) 页").font(.caption)
            }.disabled(working)
            HSplitView {
                List(selection: $focused) {
                    ForEach(candidates) { value in
                        HStack {
                            Toggle("删除", isOn: Binding(get: { selected.contains(value.page) }, set: { if $0 { selected.insert(value.page) } else { selected.remove(value.page) } })).labelsHidden()
                            Text(value.title).font(.callout)
                        }.tag(value.page)
                    }
                }.frame(minWidth: 280, idealWidth: 310)
                HStack {
                    preview(candidate?.page, title: "待检查页")
                    if let original = candidate?.original { preview(original, title: "保留的原页") }
                }.frame(minWidth: 400, maxWidth: .infinity)
            }
            Text(message).font(.callout)
            Text("仅标记疑似页面，默认不勾选。空白判断会保护含文字的页面；带批注或链接的页面跳过。重复判断结合预览、尺寸与文字层，请并排核对后删除；操作可撤销。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("关闭") { worker?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("删除勾选页（\(selected.count)）") {
                    if let snapshot, workspace.removeInspectedPages(selected, snapshot: snapshot) { dismiss() }
                    else { message = workspace.error ?? "删除未完成"; workspace.error = nil }
                }.disabled(working || selected.isEmpty || selected.count >= workspace.count)
            }
        }.padding(20).adaptiveSheet(width: 1060, height: 740)
        .onAppear { scan() }.onDisappear { worker?.cancel() }
    }
    private func preview(_ index: Int?, title: String) -> some View {
        VStack {
            Text(title + (index.map { " · 第 \($0 + 1) 页" } ?? "")).font(.caption)
            if let index, let page = document?.page(at: index) { InspectionPDFPreview(page: page) }
            else { Text("选择左侧页面查看").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    private func scan() {
        do {
            let data = try workspace.pdfData()
            snapshot = data; document = PDFDocument(data: data); selected = []; focused = nil; candidates = []
            working = true; message = "正在逐页检查…"
            let job = Task.detached(priority: .userInitiated) { try PageInspection.scan(data) }; worker = job
            Task {
                defer { working = false }
                do {
                    let values = try await job.value
                    guard !job.isCancelled else { return }
                    candidates = values; focused = values.first?.page
                    message = "检查完成：疑似空白 \(values.filter { $0.kind == .blank }.count) 页，重复副本 \(values.filter { $0.kind == .duplicate }.count) 页。"
                } catch is CancellationError { message = "检查已停止" }
                catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}

struct InspectionPDFPreview: NSViewRepresentable {
    let page: PDFPage
    final class Coordinator { var page: PDFPage? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePage; return view }
    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.page !== page else { return }
        context.coordinator.page = page
        let document = PDFDocument(); document.insert(page.copy() as! PDFPage, at: 0); view.document = document
    }
}
