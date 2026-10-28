import SwiftUI

/// How far through the book the reader is, chapter by chapter, and a way to carry on.
struct ReadingProgressSheet: View {
    @ObservedObject var workspace: Workspace
    @AppStorage(AppInterface.resumeReadingKey) private var resumeReading = true

    private var chapters: [ReadingProgress.Chapter] {
        ReadingProgress.chapters(outline: workspace.outlineEntries, visited: workspace.readingProgress.visited, pageCount: workspace.count)
    }

    var body: some View {
        let progress = workspace.readingProgress
        VStack(alignment: .leading, spacing: 10) {
            PanelRow {
                Text("阅读进度").font(.headline)
                Spacer()
                Button("完成") { workspace.showProgress = false }.keyboardShortcut(.defaultAction)
            }
            let fraction = progress.fraction(pageCount: workspace.count)
            ProgressView(value: fraction)
            Text("已读 \(progress.visited.filter { $0 < workspace.count }.count) / \(workspace.count) 页（\(Int(fraction * 100))%）；上次读到第 \(progress.last + 1) 页")
                .font(.callout)
            PanelRow {
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
                        PanelRow {
                            Text(String(repeating: "　", count: chapter.depth) + chapter.title).lineLimit(1)
                            Spacer()
                            ProgressView(value: chapter.fraction).frame(width: 90)
                            Text("\(chapter.visitedCount)/\(chapter.pageCount)").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("保存这本书的阅读快捷方式…") {
                workspace.showProgress = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { workspace.showReadingShortcut = true }
            }.disabled(!workspace.canCreateReadingShortcut)
            Toggle("打开书时回到上次读到的页", isOn: $resumeReading)
            Text("停留一会儿的页面才算读过；记录只保存在本机，记录页码、页面位置、缩放和阅读布局；关闭后也保留。KongSeek 的“最近阅读”和文件清单的“阅读进度”读取这份记录。").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .adaptiveSheet(width: 560, height: 520, minimumWidth: 360)
    }
}
