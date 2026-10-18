import SwiftUI

/// How far through the book the reader is, chapter by chapter, and a way to carry on.
struct ReadingProgressSheet: View {
    @ObservedObject var workspace: Workspace

    private var chapters: [ReadingProgress.Chapter] {
        ReadingProgress.chapters(outline: workspace.outlineEntries, visited: workspace.progress.visited, pageCount: workspace.count)
    }

    var body: some View {
        let progress = workspace.progress
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("阅读进度").font(.headline)
                Spacer()
                Button("完成") { workspace.showProgress = false }.keyboardShortcut(.defaultAction)
            }
            let fraction = progress.fraction(pageCount: workspace.count)
            ProgressView(value: fraction)
            Text("已读 \(progress.visited.filter { $0 < workspace.count }.count) / \(workspace.count) 页（\(Int(fraction * 100))%）；上次读到第 \(progress.last + 1) 页")
                .font(.callout)
            HStack {
                Button("回到上次读到的页") { workspace.selectPage(min(progress.last, max(0, workspace.count - 1))); workspace.showProgress = false }
                    .disabled(progress.visited.isEmpty)
                Button("跳到下一个没读过的页") {
                    if let next = progress.nextUnread(after: workspace.selection, pageCount: workspace.count) {
                        workspace.selectPage(next); workspace.showProgress = false
                    }
                }
                .disabled(progress.nextUnread(after: workspace.selection, pageCount: workspace.count) == nil)
                Spacer()
                Button("清除记录", role: .destructive) { workspace.clearProgress() }
            }
            Divider()
            if chapters.isEmpty {
                Text("这份文档没有目录，因此不分章节统计。").font(.caption).foregroundStyle(.secondary)
            } else {
                List(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                    Button {
                        workspace.selectPage(chapter.firstPage); workspace.showProgress = false
                    } label: {
                        HStack {
                            Text(String(repeating: "　", count: chapter.depth) + chapter.title).lineLimit(1)
                            Spacer()
                            ProgressView(value: chapter.fraction).frame(width: 90)
                            Text("\(chapter.visitedCount)/\(chapter.pageCount)").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("停留一会儿的页面才算读过；记录只保存在本机，按文件路径区分。").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 560, height: 520)
    }
}
