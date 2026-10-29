import SwiftUI

struct ResearchRestorePreview: View {
    @ObservedObject var controller: ResearchController
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        if let backup = controller.backupPreview {
            VStack(alignment:.leading,spacing:10) {
                Text("恢复前核对").font(.headline)
                Text("书籍 \(backup.catalog.books.count) 本 · 伴随资料 \(backup.companions.count) 份 · 阅读记录 \(backup.progress.count) 本 · 草稿 \(backup.companions.filter { $0.path.contains("Drafts/") }.count) 份").font(.caption)
                HStack { Button("全选") { controller.backupSelection = Set(backup.catalog.books.map(\.path)) }; Button("全不选") { controller.backupSelection = [] } }
                ForEach(backup.catalog.books) { book in
                    HStack {
                        Toggle(book.title,isOn:Binding(get:{controller.backupSelection.contains(book.path)},set:{ if $0 { controller.backupSelection.insert(book.path) } else { controller.backupSelection.remove(book.path) } }))
                        Spacer()
                        Text(backup.originals[ReadingProgress.canonicalPath(book.path)] == nil ? "未打包原件，恢复时检查位置" : "含原件副本").font(.caption)
                        if store.library.books.contains(where: { $0.id == book.id || ReadingProgress.canonicalPath($0.path) == ReadingProgress.canonicalPath(book.path) }) { Text("书架已有记录；含原件时另建独立副本").font(.caption).foregroundStyle(.orange) }
                    }
                }
                Toggle("同时恢复公共笔记、图片资源和工作区",isOn:$controller.backupIncludeShared)
                Text("所选书籍的书签、校对、阅读尺和草稿随书恢复；共享笔记可单独选择。所有文件先恢复到新目录，已有资料继续保留。").font(.caption)
                HStack { Button("选择目录并恢复所选资料…") { controller.restoreSelectedBackup(store) }.disabled(controller.busy || controller.backupSelection.isEmpty); Button("关闭预览") { controller.backupPreview = nil }.disabled(controller.busy) }
            }.padding(10).background(.quaternary.opacity(0.3))
        }
    }
}
