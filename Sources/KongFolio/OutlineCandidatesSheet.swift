import SwiftUI

/// Headings found at the start of pages; the ones ticked go into the table of contents.
struct OutlineCandidatesSheet: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("找到的卷、章标题").font(.title2.bold())
            if workspace.outlineCandidates.isEmpty {
                Text(workspace.outlineCandidatesHadText ? "没有在页首找到“卷之一”“第二章”“序”“凡例”这类标题。" : "这些页面没有文字。请先运行 OCR（竖排书请选“竖排”）。")
                    .foregroundStyle(.secondary)
            } else {
                Text("共 \(workspace.outlineCandidates.count) 处，勾选的会加入目录（已有的同页同名条目不会重复）。")
                List(workspace.outlineCandidates) { item in
                    Toggle(isOn: Binding(get: { workspace.outlineCandidatesChosen.contains(item.id) }, set: { on in
                        if on { workspace.outlineCandidatesChosen.insert(item.id) } else { workspace.outlineCandidatesChosen.remove(item.id) }
                    })) {
                        HStack {
                            Text(String(repeating: "　", count: item.depth) + item.title)
                            Spacer()
                            Text("第 \(item.page + 1) 页").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 280)
            }
            Text("只看每页最前面的几行（竖排书是最右边的几列）。识别有误时标题也会错，加入后可在目录里改名。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("关闭") { workspace.showOutlineCandidates = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("加入目录") { workspace.addChosenOutlineCandidates(); workspace.showOutlineCandidates = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(workspace.outlineCandidatesChosen.isEmpty || workspace.outlineCandidates.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
