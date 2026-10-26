import SwiftUI
import AppKit

struct OCRReview: View {
    @ObservedObject var workspace: Workspace
    @State private var page = 0
    @State private var lines: [RecognizedLine] = []
    @State private var initial: [RecognizedLine] = []
    @State private var image: NSImage?
    @State private var doubtfulOnly = false
    private var editable: Bool { workspace.meta(page).ocrOriginal != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OCR 对照校正 · 第 \(page + 1) 页").font(.headline)
                Toggle("只看低置信度与已改行", isOn: $doubtfulOnly)
                Spacer()
                Button("取消") { workspace.showOCRReview = false }
                Button("应用校正") { if workspace.applyOCRCorrections(lines, page: page, expected: initial) { workspace.showOCRReview = false } }
                    .disabled(!editable || lines == initial).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(lines.indices, id: \.self) { index in
                        if !doubtfulOnly || lines[index].confidence < OCRQuality.lowConfidence || lines[index] != initial[index] {
                            HStack(alignment: .top, spacing: 16) {
                                if let crop = crop(lines[index].box) { Image(nsImage: crop).resizable().scaledToFit().frame(width: 270, height: 100).background(.white) }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("第 \(index + 1) 行 · 置信度 \(Int(lines[index].confidence * 100))%").font(.caption)
                                        Spacer()
                                        Button("恢复识别原文") { lines[index].text = initial[index].originalText ?? initial[index].text }.font(.caption)
                                    }
                                    TextField("识别文字", text: $lines[index].text, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 17)).disabled(!editable)
                                    if let original = lines[index].originalText { Text("识别原文：" + original).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if lines.isEmpty { Text("此页尚无识别记录，请先执行 OCR。").foregroundStyle(.secondary) }
                }
            }
            Text(editable ? "左侧对照原图，右侧直接改字。应用时从 OCR 前原页重建文字层，保留识别原文与现有标注，可撤销。竖排也可使用“逐列校对”。" : "此页只有检查记录，没有 OCR 前原页。请先执行 OCR，再校正并保存文字层。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 940, height: 680)
        .onAppear { page = workspace.selection; lines = workspace.meta(page).ocrRegions ?? []; initial = lines; image = workspace.pageDisplayImage(maxDimension: 2400) }
        .alert("校正失败", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) { Button("好") { workspace.error = nil } } message: { Text(workspace.error ?? "") }
    }
    private func crop(_ box: CGRect) -> NSImage? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cg.cropping(to: ColumnProofreading.cropRect(box: box, imageSize: CGSize(width: cg.width, height: cg.height), padding: 0.015)) else { return nil }
        return NSImage(cgImage: cropped, size: .zero)
    }
}
