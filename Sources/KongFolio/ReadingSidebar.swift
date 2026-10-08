import SwiftUI

struct ReadingSidebar: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch workspace.sidebarTab {
            case "目录":
                if workspace.outlineEntries.isEmpty { Text("此文档没有内嵌目录。可添加自己的书签。").font(.caption).foregroundStyle(.secondary).padding() }
                ScrollView { LazyVStack(alignment: .leading, spacing: 6) { ForEach(workspace.outlineEntries) { entry in
                    Button { workspace.openOutline(entry) } label: { VStack(alignment: .leading, spacing: 3) { Text(entry.label).lineLimit(3); Text("第 \(entry.page + 1) 页").font(.caption).foregroundStyle(.secondary) }.padding(.leading, CGFloat(min(4, entry.depth)) * 10).padding(6).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                } }.padding(8) }
            case "书签":
                VStack(spacing: 8) { TextField("书签名称（可选）", text: $workspace.bookmarkName); Button("添加当前页") { workspace.addBookmark() }.disabled(workspace.count == 0) }.padding(.horizontal, 10)
                List { ForEach(workspace.bookmarks) { bookmark in HStack { Button { workspace.selectPage(bookmark.page) } label: { VStack(alignment: .leading) { Text(bookmark.label); Text("第 \(bookmark.page + 1) 页").font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain); Spacer(); Button { workspace.deleteBookmark(bookmark.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain) } } }
            case "搜索":
                HStack { TextField("搜索文档", text: $workspace.search).onSubmit { workspace.find() }; Button { workspace.find() } label: { Image(systemName: "magnifyingglass") } }.padding(.horizontal, 10)
                Text(workspace.searchMessage).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                ScrollView { LazyVStack(spacing: 8) { ForEach(workspace.searchResults) { hit in Button { workspace.goToSearch(hit) } label: { VStack(alignment: .leading, spacing: 5) { Text("第 \(hit.page + 1) 页").font(.caption.bold()).foregroundStyle(.teal); Text(hit.snippet).font(.caption).lineLimit(5) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain) } }.padding(8) }
            default:
                HStack { Button("刷新") { workspace.refreshNotes() }; Button("导出 Markdown") { workspace.exportNotes() }.disabled(workspace.count == 0) }.font(.caption).padding(.horizontal, 8)
                if workspace.annotationNotes.isEmpty { Text("尚无摘录或标注。选中文字后，可在右侧输入笔记并高亮。").font(.caption).foregroundStyle(.secondary).padding() }
                ScrollView { LazyVStack(spacing: 8) { ForEach(workspace.annotationNotes) { entry in Button { workspace.goToNote(entry) } label: { VStack(alignment: .leading, spacing: 5) { Text("第 \(entry.page + 1) 页 · \(entry.kind)").font(.caption.bold()).foregroundStyle(.teal); if !entry.quote.isEmpty { Text(entry.quote).font(.caption).lineLimit(5) }; if !entry.note.isEmpty { Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(4) } }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain) } }.padding(8) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if workspace.sidebarTab == "摘录" { workspace.refreshNotes() } }
        .onChange(of: workspace.sidebarTab) { _, tab in if tab == "摘录" { workspace.refreshNotes() } }
    }
}
