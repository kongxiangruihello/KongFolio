import SwiftUI

/// Arranges the notes outline before it is exported: order, chapter, tags, duplicates.
struct OutlineEditorView: View {
    @ObservedObject var workspace: Workspace
    @State private var draft = OutlineDraft(sections: [])
    @State private var tagText: [String: String] = [:]
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("整理笔记大纲").font(.headline)
                Text("\(draft.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("合并重复") {
                    let n = draft.mergeDuplicates()
                    message = n == 0 ? "没有重复的条目" : "已合并 \(n) 条重复的"
                }
                Button("重新生成") { load(fresh: true) }
                Menu("导出") {
                    Button("Word（按章节）…") { workspace.writeNotesOutline(draft.exportSections, .word) }
                    Button("Markdown…") { workspace.writeNotesOutline(draft.exportSections, .markdown) }
                    Button("文本…") { workspace.writeNotesOutline(draft.exportSections, .text) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("完成") { workspace.showOutlineEditor = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if draft.count == 0 {
                Text("没有可整理的标注或摘录。").foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                List {
                    ForEach(Array(draft.sections.enumerated()), id: \.offset) { s, section in
                        if !section.notes.isEmpty {
                            Section(String(repeating: "　", count: section.depth) + section.title) {
                                ForEach(section.notes) { note in row(note, sectionIndex: s) }
                            }
                        }
                    }
                }
            }
            Text(message.isEmpty ? "标签会以 #标签 的形式写进导出的大纲；顺序、章节和删除只影响导出，不改动文档里的标注。" : message)
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 720, height: 620)
        .onAppear { load(fresh: false) }
        .onDisappear { workspace.outlineDraft = draft }
    }

    private func row(_ note: AnnotationNote, sectionIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(note.pageDescription) · \(note.kind)").font(.caption.bold()).foregroundStyle(Brand.accent)
                Spacer()
                Button { draft.move(note.id, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).help("上移")
                Button { draft.move(note.id, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.plain).help("下移")
                Menu {
                    ForEach(Array(draft.sections.enumerated()), id: \.offset) { index, section in
                        if index != sectionIndex { Button(section.title) { draft.move(note.id, toSection: index) } }
                    }
                } label: { Image(systemName: "arrow.right.square") }
                    .menuStyle(.borderlessButton).fixedSize().help("移到别的章节")
                Button { draft.remove(note.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("从大纲中去掉")
            }
            if !note.quote.isEmpty { Text(note.quote).font(.callout).lineLimit(3) }
            if !note.note.isEmpty { Text(note.note).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            TextField("标签（逗号分隔）", text: Binding(
                get: { tagText[note.id] ?? note.tags.joined(separator: ", ") },
                set: { tagText[note.id] = $0; draft.setTags(note.id, OutlineDraft.parseTags($0)) }
            ))
            .textFieldStyle(.roundedBorder).font(.caption)
        }
        .padding(.vertical, 3)
    }

    private func load(fresh: Bool) {
        if !fresh, let kept = workspace.outlineDraft {
            draft = kept
            message = "已恢复上次整理的结果；点“重新生成”可按文档现状重来"
        } else {
            draft = OutlineDraft(sections: workspace.notesOutlineSections())
            message = ""
        }
        tagText = [:]
    }
}
