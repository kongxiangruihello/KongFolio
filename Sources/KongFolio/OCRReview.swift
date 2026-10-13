import SwiftUI

struct OCRReview: View {
    @ObservedObject var workspace: Workspace
    private var lines: [RecognizedLine] { workspace.ocrRegions[workspace.selection] ?? [] }
    var body: some View {
        VStack {
            HStack { Text("OCR 区域检查 · 第 \(workspace.selection + 1) 页").font(.headline); Spacer(); Button("完成") { workspace.showOCRReview = false } }.padding()
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    if let image = workspace.pageDisplayImage(maxDimension: 1500) {
                        let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Button { workspace.reviewSelection = index } label: {
                                    Rectangle().fill(index == workspace.reviewSelection ? Color.orange.opacity(0.25) : .clear).overlay(Rectangle().stroke(index == workspace.reviewSelection ? Color.orange : Brand.accent, lineWidth: 1))
                                }.buttonStyle(.plain).frame(width: line.box.width * size.width, height: line.box.height * size.height).offset(x: line.box.minX * size.width, y: (1 - line.box.maxY) * size.height)
                            }
                        }.position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                }.padding(12)
                List {
                    if lines.isEmpty { Text("未发现文字区域。可尝试提高扫描清晰度后重新检查。").foregroundStyle(.secondary) }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button { workspace.reviewSelection = index } label: { VStack(alignment: .leading, spacing: 5) { Text(line.text); Text(line.approximate == true ? "竖排模式 · 位置为近似" : "置信度 \(Int(line.confidence * 100))%").font(.caption).foregroundStyle(.secondary) }.padding(6).frame(maxWidth: .infinity, alignment: .leading).background(workspace.reviewSelection == index ? Brand.accent.opacity(0.12) : .clear) }.buttonStyle(.plain)
                    }
                }.frame(width: 300)
            }
            Text("框线显示 Vision 识别区域；点击框线或文本可对照位置。此窗口不直接修改识别文字。").font(.caption).foregroundStyle(.secondary).padding()
        }.frame(width: 1000, height: 720)
    }
}
