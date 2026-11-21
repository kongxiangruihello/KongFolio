import SwiftUI
import PDFKit

struct PDFReaderPageControls: View {
    @ObservedObject var workspace: Workspace
    @State private var pageNumber = ""
    @FocusState private var editingPage: Bool

    var body: some View {
        HStack(spacing: 4) {
            step(-1, title: "上一页", symbol: "chevron.left")
            TextField("页码", text: $pageNumber)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.caption.monospacedDigit())
                .frame(width: 42)
                .focused($editingPage)
                .accessibilityLabel("跳转到 PDF 页码")
                .help(workspace.printedPageLabel(workspace.selection)
                    .map { "印刷页码 \($0) · 输入 PDF 页码后按回车" } ?? "输入 PDF 页码后按回车")
                .onSubmit {
                    if let number = Int(pageNumber.trimmingCharacters(in: .whitespaces)), number > 0, number <= workspace.count {
                        workspace.selectPage(number - 1)
                    }
                    pageNumber = String(workspace.selection + 1)
                    editingPage = false
                }
            Text("/ \(workspace.count)").font(.caption.monospacedDigit()).lineLimit(1)
                .foregroundStyle(.secondary)
            step(1, title: "下一页", symbol: "chevron.right")
        }
        .frame(width: ReaderToolbarProfile.pageControlWidth)
        .onChange(of: workspace.selection, initial: true) { _, index in
            if !editingPage { pageNumber = String(index + 1) }
        }
        .onChange(of: editingPage) { _, focused in
            if !focused { pageNumber = String(workspace.selection + 1) }
        }
    }

    private func step(_ offset: Int, title: String, symbol: String) -> some View {
        Button { workspace.selectPage(workspace.selection + offset) } label: {
            AppIcon(symbol).font(.caption).frame(width: 15, height: 26)
        }
        .help(title).accessibilityLabel(title)
        .disabled(!(0..<workspace.count).contains(workspace.selection + offset))
    }
}

struct PDFReaderZoomActions: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button("放大") { adjust { $0.zoomIn(nil) } }
        Button("缩小") { adjust { $0.zoomOut(nil) } }
        Divider()
        Button("适合宽度") {
            adjust { view in
                guard let page = workspace.page else { return }
                let bounds = page.bounds(for: view.displayBox)
                let rotated = page.rotation % 180 != 0
                let pageWidth = rotated ? bounds.height : bounds.width
                let viewport = view.documentView?.enclosingScrollView?.contentSize.width ?? view.bounds.width
                let margins = view.displaysPageBreaks ? view.pageBreakMargins.left + view.pageBreakMargins.right : 0
                let spread: CGFloat = workspace.readingLayout == .twoUp ? 2.0 : 1.0
                guard pageWidth > 0, viewport > margins * spread else { return }
                view.autoScales = false
                view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, (viewport / spread - margins) / pageWidth))
            }
        }
        Button("适合整页") { adjust { $0.autoScales = true } }
        Button("实际大小（100%）") { adjust { $0.autoScales = false; $0.scaleFactor = 1 } }
    }

    private func adjust(_ action: (PDFView) -> Void) {
        guard let view = workspace.pdfView else { return }
        workspace.showsPageThumbnails = false
        action(view)
        workspace.captureReadingPosition()
    }
}
