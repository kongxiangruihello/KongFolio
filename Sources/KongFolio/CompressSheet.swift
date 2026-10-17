import SwiftUI

/// Chooses how strongly to shrink the file. The result is always a new file; the open document stays as it is.
struct CompressSheet: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("压缩 PDF").font(.title2.bold())
            Picker("压缩程度", selection: $workspace.compressLevel) {
                ForEach(CompressLevel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(workspace.compressLevel.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("只处理含大图片的页面；压缩后如果没有变小，不会生成文件。当前文档不会被改动，压缩结果另存为新文件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { workspace.showCompress = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("选择位置并压缩…") { workspace.startCompress() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
