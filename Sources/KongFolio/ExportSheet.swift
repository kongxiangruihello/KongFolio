import SwiftUI

struct ExportSheet: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出设置").font(.title2.bold())
            Picker("文件格式", selection: $workspace.exportOptions.format) { ForEach(["PDF", "PNG", "JPG", "TIFF"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            Picker("页面范围", selection: $workspace.exportOptions.scope) { ForEach(["全部页面", "当前页面", "选中页面"], id: \.self) { Text($0) } }
            if workspace.exportOptions.format == "PDF" {
                Toggle("生成图片型 PDF（有损压缩）", isOn: $workspace.exportOptions.rasterPDF)
                Text(workspace.exportOptions.rasterPDF ? "页面尺寸保持不变；文字、链接和标注将固化为图片。" : "保留页面原始内容、尺寸和标注，不重新采样。已有图片调整造成的栅格化不会逆转。").font(.caption).foregroundStyle(.secondary)
            }
            if workspace.exportOptions.format != "PDF" || workspace.exportOptions.rasterPDF {
                Picker("分辨率", selection: $workspace.exportOptions.dpi) { ForEach([72, 150, 300, 600], id: \.self) { Text("\($0) DPI").tag($0) } }
                if let page = workspace.page, let pixels = try? ExportServices.pixels(page, dpi: workspace.exportOptions.dpi) {
                    Text("当前页：\(Int(pixels.width)) × \(Int(pixels.height)) 像素").font(.caption).foregroundStyle(.secondary)
                }
                if workspace.exportOptions.format == "JPG" || workspace.exportOptions.rasterPDF {
                    HStack { Text("JPEG 质量"); Slider(value: $workspace.exportOptions.quality, in: 0.1...1); Text(workspace.exportOptions.quality, format: .percent.precision(.fractionLength(0))).frame(width: 45) }
                }
                Text("图片包含页面与标注外观；提高 DPI 不会恢复原图中已丢失的细节。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack { Button("估算体积") { workspace.estimateExport() }.disabled(workspace.estimating); if workspace.estimating { ProgressView().controlSize(.small) }; Text("\(workspace.exportPages.count) 页").foregroundStyle(.secondary) }
            if let estimate = workspace.exportEstimate {
                Text("\(estimate.exact ? "预计体积" : "约")：\(ByteCountFormatter.string(fromByteCount: Int64(estimate.bytes), countStyle: .file))").font(.headline)
                if !estimate.exact { Text("基于前 \(estimate.sampled) 页估算，复杂度不同会影响实际大小。").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { Button("取消") { workspace.showExport = false }; Spacer(); Button("选择位置并导出…") { workspace.configuredExport() }.buttonStyle(.borderedProminent).tint(.teal) }
        }.padding(28).frame(width: 560)
        .onChange(of: workspace.exportOptions) { _, _ in workspace.invalidateEstimate() }
        .onDisappear { workspace.invalidateEstimate() }
    }
}
