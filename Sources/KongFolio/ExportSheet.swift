import SwiftUI

struct ExportSheet: View {
    @ObservedObject var workspace: Workspace

    private var stampControls: some View {
        DisclosureGroup("页码、页眉页脚与水印") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("页码", selection: $workspace.exportOptions.stamp.numberFormat) {
                    ForEach(PageNumberFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if workspace.exportOptions.stamp.numberFormat != .none {
                    Picker("位置", selection: $workspace.exportOptions.stamp.numberPosition) {
                        ForEach(PageNumberPosition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("起始页码：\(workspace.exportOptions.stamp.startNumber)", value: $workspace.exportOptions.stamp.startNumber, in: 0...9999)
                }
                TextField("页眉（左上）", text: $workspace.exportOptions.stamp.header)
                TextField("页脚（左下）", text: $workspace.exportOptions.stamp.footer)
                TextField("水印文字（斜向居中）", text: $workspace.exportOptions.stamp.watermark)
                Stepper("字号：\(Int(workspace.exportOptions.stamp.fontSize)) pt", value: $workspace.exportOptions.stamp.fontSize, in: 6...24)
                if workspace.exportOptions.stamp.isActive {
                    Text("叠加后页面会被重新绘制：文字保持可搜索，目录保留；标注固化到页面，链接不再可点。已有的页码会和新页码重叠，请先确认原文件没有页码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出设置").font(.title2.bold())
            Picker("页面范围", selection: $workspace.exportOptions.scope) {
                ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) }
            }
            if workspace.exportOptions.format == .pdf {
                Picker("PDF 类型", selection: $workspace.exportOptions.pdfMode) {
                    ForEach(PDFExportMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(workspace.exportOptions.pdfMode.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if workspace.exportOptions.format == .pdf {
                Toggle("末尾附标注摘要页（每条标注的页码、原文和笔记）", isOn: Binding(get: { workspace.exportOptions.appendsNotes }, set: { workspace.exportOptions.appendsNotes = $0 }))
                    .disabled(workspace.exportOptions.scope != .all)
                if workspace.exportOptions.scope != .all {
                    Text("摘要页只在导出全部页面时可用，因为页码要与整本书对应。").font(.caption).foregroundStyle(.secondary)
                }
                stampControls
            }
            if workspace.exportOptions.rendersPixels {
                Picker("分辨率", selection: $workspace.exportOptions.dpi) {
                    ForEach([72, 150, 300, 600], id: \.self) { Text("\($0) DPI").tag($0) }
                }
                if let page = workspace.page, let pixels = try? ExportServices.pixels(page, dpi: workspace.exportOptions.dpi) {
                    Text("当前页：\(Int(pixels.width)) × \(Int(pixels.height)) 像素").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("JPEG 质量")
                    Slider(value: $workspace.exportOptions.quality, in: 0.1...1)
                    Text(workspace.exportOptions.quality, format: .percent.precision(.fractionLength(0))).frame(width: 45)
                }
                Text("图片型 PDF 把每页重绘为图片；提高 DPI 不会恢复原图中已丢失的细节。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("估算体积") { workspace.estimateExport() }.disabled(workspace.estimating)
                if workspace.estimating { ProgressView().controlSize(.small) }
                Text("\(workspace.exportPages.count) 页").foregroundStyle(.secondary)
            }
            if let estimate = workspace.exportEstimate {
                Text("\(estimate.exact ? "预计体积" : "约")：\(ByteCountFormatter.string(fromByteCount: Int64(estimate.bytes), countStyle: .file))").font(.headline)
                if !estimate.exact { Text("基于前 \(estimate.sampled) 页估算，复杂度不同会影响实际大小。").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("取消") { workspace.showExport = false }
                Spacer()
                Button("选择位置并导出…") { workspace.configuredExport() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 560)
        .tint(Brand.accent)
        .onChange(of: workspace.exportOptions) { _, _ in workspace.invalidateEstimate() }
        .onDisappear { workspace.invalidateEstimate() }
    }
}
