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
            DisclosureGroup("与校对稿比较（测算字准确率）") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把当前第 \(workspace.selection + 1) 页校对好的文字粘贴在下面（标点、空白不计），按键即可得到识别的字准确率。换一种识别设置后再比较一次，就知道哪种更准。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $workspace.accuracyReference).font(.system(size: 12)).frame(height: 90).border(Color.secondary.opacity(0.4))
                    PanelRow {
                        Button("计算") { workspace.compareAccuracy() }
                        if !workspace.accuracyMessage.isEmpty { Text(workspace.accuracyMessage).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            PanelRow {
                Button("关闭") { workspace.showOCRQuality = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("重新识别这些页") { workspace.recognizeDoubtfulAgain() }
                    .disabled(workspace.ocrDoubtful.isEmpty || workspace.busy)
            }
        }
        .padding(24)
        .adaptiveSheet(width: 460, height: 600, minimumWidth: 360)
    }
}
