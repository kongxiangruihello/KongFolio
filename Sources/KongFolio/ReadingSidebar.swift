import SwiftUI

struct ReadingSidebar: View {
    @ObservedObject var workspace: Workspace
    @State private var outlineTitle = ""
    @State private var outlineDepth = 0
    @State private var editingOutline: UUID?
    @State private var editedTitle = ""

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

    private func addOutline() {
        workspace.addOutlineEntry(title: outlineTitle, depth: outlineDepth)
        outlineTitle = ""
    }

    private var outline: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                TextField("目录条目名称（可选）", text: $outlineTitle).onSubmit(addOutline)
                HStack {
                    Picker("级别", selection: $outlineDepth) { ForEach(0..<4) { Text("第 \($0 + 1) 级").tag($0) } }.labelsHidden().frame(width: 90)
                    Button("把当前页加入目录", action: addOutline).disabled(workspace.count == 0)
                }
                Button("阅读快捷方式…") { workspace.showReadingShortcut = true }.disabled(!workspace.canCreateReadingShortcut)
                Button("阅读进度…") { workspace.refreshProgress(); workspace.showProgress = true }.disabled(workspace.count == 0)
                HStack {
                    Button("编辑目录文本…") { workspace.showOutlineText = true }
                    Button("找卷、章标题…") { workspace.findOutlineCandidates() }
                }
                .disabled(workspace.count == 0)
                if workspace.outlineEntries.isEmpty {
                    Text("此文档没有目录。给章节的起始页加入目录后，导出或另存为 PDF 时会写进文件，也可用来按章节拆分。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
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
                        if editingOutline == entry.id {
                            TextField("名称", text: $editedTitle)
                                .onSubmit { workspace.renameOutlineEntry(entry.id, to: editedTitle); editingOutline = nil }
                                .padding(.leading, CGFloat(min(4, entry.depth)) * 10 + 6)
                        } else {
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
                            .contextMenu {
                                Button("重命名…") { editedTitle = entry.label; editingOutline = entry.id }
                                Button("降一级（缩进）") { workspace.indentOutlineEntry(entry.id, by: 1) }
                                Button("升一级") { workspace.indentOutlineEntry(entry.id, by: -1) }
                                Divider()
                                Button("删除这一条", role: .destructive) { workspace.deleteOutlineEntry(entry.id) }
                                Button("清除整个目录", role: .destructive) { workspace.clearOutline() }
                            }
                        }
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
            batchControls
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shownNotes) { entry in
                        HStack(alignment: .top, spacing: 6) {
                        Button { workspace.toggleNote(entry.id) } label: {
                            Image(systemName: workspace.selectedNoteIDs.contains(entry.id) ? "checkmark.square.fill" : "square").padding(.top, 10)
                        }
                        .buttonStyle(.plain)
                        .help("勾选，用于批量删除或改色")
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
                }
                .padding(8)
            }
        }
    }

    private let batchColors: [(name: String, color: Color)] = [("红", .red), ("橙", .orange), ("黄", .yellow), ("绿", .green), ("蓝", .blue), ("黑", .black)]

    /// Select-all / delete / recolour for the ticked entries; only annotations can be changed, excerpts are left alone.
    @ViewBuilder private var batchControls: some View {
        if !workspace.annotationNotes.isEmpty {
            HStack(spacing: 6) {
                Button("全选显示的") { workspace.selectNotes(shownNotes) }
                if !workspace.selectedNoteIDs.isEmpty {
                    Button("清除选择") { workspace.selectedNoteIDs = [] }
                    Button("删除选中（\(workspace.selectedNoteIDs.count)）", role: .destructive) { workspace.deleteSelectedNotes() }
                    Menu("排列") {
                        Button("左对齐") { workspace.alignSelectedNotes(.left) }
                        Button("右对齐") { workspace.alignSelectedNotes(.right) }
                        Button("顶对齐") { workspace.alignSelectedNotes(.top) }
                        Button("底对齐") { workspace.alignSelectedNotes(.bottom) }
                        Button("水平居中") { workspace.alignSelectedNotes(.centerX) }
                        Button("垂直居中") { workspace.alignSelectedNotes(.centerY) }
                        Divider()
                        Button("横向等距（至少 3 个）") { workspace.distributeSelectedNotes(horizontally: true) }
                        Button("纵向等距（至少 3 个）") { workspace.distributeSelectedNotes(horizontally: false) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    ForEach(batchColors, id: \.name) { item in
                        Button { workspace.recolorSelectedNotes(NSColor(item.color)) } label: {
                            Circle().fill(item.color).frame(width: 13, height: 13)
                        }
                        .buttonStyle(.plain)
                        .help("选中的标注改为\(item.name)色")
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
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
