import SwiftUI

struct ReadingSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch workspace.sidebarTab {
            case .outline: outline
            case .bookmarks: bookmarks
            case .search: searchResults
            case .notes, .pages: notes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if workspace.sidebarTab == .notes { workspace.refreshNotes() } }
        .onChange(of: workspace.sidebarTab) { _, tab in if tab == .notes { workspace.refreshNotes() } }
    }

    private var outline: some View {
        Group {
            if workspace.outlineEntries.isEmpty {
                Text("此文档没有内嵌目录。可添加自己的书签。").font(.caption).foregroundStyle(.secondary).padding()
            }
            if !workspace.outlineEntries.isEmpty {
                Menu("按章节拆分为多个 PDF…") {
                    ForEach(ChapterSplit.depths(workspace.outlineEntries, pageCount: workspace.count), id: \.self) { depth in
                        Button("按第 \(depth + 1) 级目录（\(workspace.chapterCount(depth: depth)) 个文件）") { workspace.splitByChapters(depth: depth) }
                    }
                }
                .disabled(workspace.busy)
                .padding(.horizontal, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(workspace.outlineEntries) { entry in
                        Button { workspace.openOutline(entry) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.label).lineLimit(3)
                                Text(pageText(entry.page)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.leading, CGFloat(min(4, entry.depth)) * 10)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    private var bookmarks: some View {
        Group {
            VStack(spacing: 8) {
                TextField("书签名称（可选）", text: $workspace.bookmarkName)
                Button("添加当前页") { workspace.addBookmark() }.disabled(workspace.count == 0)
            }
            .padding(.horizontal, 10)
            List {
                ForEach(workspace.bookmarks) { bookmark in
                    HStack {
                        Button { workspace.selectPage(bookmark.page) } label: {
                            VStack(alignment: .leading) {
                                Text(bookmark.label)
                                Text(pageText(bookmark.page)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { workspace.deleteBookmark(bookmark.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        Group {
            HStack {
                TextField("搜索文档（简繁通查）", text: $workspace.search).onSubmit { workspace.find() }
                Button { workspace.find() } label: { Image(systemName: "magnifyingglass") }
            }
            .padding(.horizontal, 10)
            Text(workspace.searchMessage).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(workspace.searchResults) { hit in
                        Button { workspace.goToSearch(hit) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(hit.label.map { "第 \(hit.page + 1) 页 · 印刷页码 \($0)" } ?? "第 \(hit.page + 1) 页").font(.caption.bold()).foregroundStyle(Brand.accent)
                                Text(hit.snippet).font(.caption).lineLimit(5)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    private var shownNotes: [AnnotationNote] { workspace.noteFilter.apply(to: workspace.annotationNotes) }

    private var notes: some View {
        Group {
            HStack {
                Button("刷新") { workspace.refreshNotes() }
                Button("导出 Markdown") { workspace.exportNotes(filter: workspace.noteFilter) }.disabled(workspace.count == 0)
                Button("转为笔记标签页") { workspace.openNotesAsNote(filter: workspace.noteFilter) }.disabled(workspace.count == 0)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            HStack(spacing: 6) {
                Picker("类型", selection: $workspace.noteFilter.kind) {
                    Text("全部类型").tag(String?.none)
                    ForEach(AnnotationFilter.kinds, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                Picker("颜色", selection: $workspace.noteFilter.color) {
                    Text("全部颜色").tag(String?.none)
                    ForEach(AnnotationFilter.colors, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            TextField("在标注和笔记中搜索", text: $workspace.noteFilter.text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .padding(.horizontal, 8)
            if workspace.noteFilter.isActive {
                Text("显示 \(shownNotes.count) / \(workspace.annotationNotes.count) 条").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            DisclosureGroup("书目信息（用于引用）") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("作者", text: bibliographyBinding(\.author))
                    TextField("书名", text: bibliographyBinding(\.title))
                    TextField("版本 / 卷次", text: bibliographyBinding(\.edition))
                    TextField("出版者", text: bibliographyBinding(\.publisher))
                    TextField("出版年", text: bibliographyBinding(\.year))
                    if !workspace.bibliography.isEmpty {
                        Text(workspace.bibliography.citation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            if workspace.annotationNotes.isEmpty {
                Text("尚无摘录或标注。选中文字后，可在右侧输入笔记并标记。").font(.caption).foregroundStyle(.secondary).padding()
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shownNotes) { entry in
                        Button { workspace.goToNote(entry) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    if let rgb = entry.rgb, rgb.count == 3 {
                                        Circle().fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2])).frame(width: 9, height: 9)
                                    }
                                    Text("\(entry.pageDescription) · \(entry.kind)").font(.caption.bold()).foregroundStyle(Brand.accent)
                                }
                                if !entry.quote.isEmpty { Text(entry.quote).font(.caption).lineLimit(5) }
                                if !entry.note.isEmpty { Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    private func pageText(_ index: Int) -> String {
        guard let page = workspace.document.page(at: index), let label = ReadingServices.pageLabel(page, index: index) else { return "第 \(index + 1) 页" }
        return "第 \(index + 1) 页 · 印刷页码 \(label)"
    }

    private func bibliographyBinding(_ key: WritableKeyPath<Bibliography, String>) -> Binding<String> {
        Binding(
            get: { workspace.bibliography[keyPath: key] },
            set: { value in
                guard workspace.bibliography[keyPath: key] != value else { return }
                workspace.bibliography[keyPath: key] = value
                workspace.dirty = true
                workspace.scheduleRecovery()
            }
        )
    }
}
