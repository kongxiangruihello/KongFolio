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
            if workspace.compressLevel != .light {
                if let scan = workspace.compressScan {
                    if scan.pictureHeavy == 0 {
                        Text("这份文档里没有含大图片的页面，标准/强力压缩不会改动它。").font(.callout)
                    } else {
                        Text("含大图片的页面：\(scan.pictureHeavy) 页，其中 \(scan.marked) 页带有批注或链接。").font(.callout)
                    }
                } else {
                    Text("正在检查页面…").font(.callout).foregroundStyle(.secondary)
                }
                Toggle("不压缩带批注或链接的页面（保持可编辑、可点击）", isOn: $workspace.compressKeepMarked)
                Text(workspace.compressKeepMarked ? "这些页面会原样保留，体积不会减少。" : "这些页面会被重绘：批注和链接固化为图像，不能再编辑或点击。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
