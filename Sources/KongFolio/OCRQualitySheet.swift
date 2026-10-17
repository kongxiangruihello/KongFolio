import SwiftUI

/// Pages whose recognition looks doubtful, so a long book does not have to be checked page by page.
struct OCRQualitySheet: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OCR 质量检查").font(.title2.bold())
            if workspace.ocrChecked == 0 {
                Text("还没有页面带有识别记录。先运行 OCR（竖排书请选“竖排”），再来检查。").foregroundStyle(.secondary)
            } else {
                Text("共检查 \(workspace.ocrChecked) 页，\(workspace.ocrDoubtful.isEmpty ? "没有发现可疑页面。" : "\(workspace.ocrDoubtful.count) 页可疑：")")
                if !workspace.ocrDoubtful.isEmpty {
                    List(workspace.ocrDoubtful) { item in
                        Button {
                            workspace.selectPage(item.page)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(item.page + 1) 页").bold()
                                Text(item.reasons.joined(separator: "；")).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 260)
                }
            }
            Text("只检查在本项目里做过 OCR、留有识别记录的页面。判断依据：识别出的字很少、有列没能逐字对位、置信度偏低。这只是提示，不代表一定有错，请对照原图核实。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("关闭") { workspace.showOCRQuality = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("重新识别这些页") { workspace.recognizeDoubtfulAgain() }
                    .disabled(workspace.ocrDoubtful.isEmpty || workspace.busy)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
