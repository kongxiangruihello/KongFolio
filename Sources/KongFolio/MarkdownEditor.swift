import PDFKit
import SwiftUI

/// Editor on the left, typeset preview (the same A4 layout used when a Markdown file is opened) on the right.
struct MarkdownEditorView: View {
    @ObservedObject var note: MarkdownNote

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                toolbar
                Divider()
                HSplitView {
                    MarkdownTextView(note: note).frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    if LayoutMetrics.showsPreview(preferred: note.showPreview, width: proxy.size.width) {
                        MarkdownPreview(note: note).frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Divider()
                HStack {
                    Text(note.status.isEmpty ? (note.fileURL?.path ?? "尚未保存到文件") : note.status).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text("\(note.characterCount) 字").lineLimit(1).fixedSize()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(width: proxy.size.width)
        }
        .alert("无法完成操作", isPresented: Binding(get: { note.error != nil }, set: { if !$0 { note.error = nil } })) {
            Button("好") { note.error = nil }
        } message: { Text(note.error ?? "") }
    }

    private var toolbar: some View {
        // Scrolls sideways when the window is narrower than the buttons.
        ScrollView(.horizontal, showsIndicators: false) { toolbarButtons }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 6) {
            Button("保存") { note.save() }.help("保存当前文件（⌘S）")
            Button("另存为…") { note.save(asNew: true) }
            Text(note.format.rawValue).font(.caption).foregroundStyle(.secondary)
            Button("打印…") { do { DocumentPrinting.printDocument(try note.renderDocument()) } catch { note.error = error.localizedDescription } }
            Divider().frame(height: 18)
            Group {
            Menu("标题") {
                Button("一级标题") { note.prefixLines("# ") }
                Button("二级标题") { note.prefixLines("## ") }
                Button("三级标题") { note.prefixLines("### ") }
            }.frame(width: 70)
            Button { note.wrap("**", "**", placeholder: "粗体") } label: { Image(systemName: "bold") }.help("粗体")
            Button { note.wrap("*", "*", placeholder: "斜体") } label: { Image(systemName: "italic") }.help("斜体")
            Button { note.wrap("`", "`", placeholder: "代码") } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.help("行内代码")
            Button { note.wrap("[", "](https://)", placeholder: "链接文字") } label: { Image(systemName: "link") }.help("链接")
            Button { note.prefixLines("- ") } label: { Image(systemName: "list.bullet") }.help("无序列表")
            Button { note.prefixLines("1. ") } label: { Image(systemName: "list.number") }.help("有序列表")
            Button { note.prefixLines("> ") } label: { Image(systemName: "text.quote") }.help("引用")
            Button { note.wrap("```\n", "\n```", placeholder: "代码") } label: { Image(systemName: "curlybraces") }.help("代码块")
            }.disabled(note.format != .markdown)
            Spacer()
            Toggle("预览", isOn: $note.showPreview).toggleStyle(.switch).controlSize(.small)
            Button("导出 PDF…") { note.exportPDF() }.help("按预览的版式导出为 PDF（⌘E）")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// Plain-text NSTextView bound to the note; it gives selection access for the formatting buttons and native undo.
struct MarkdownTextView: NSViewRepresentable {
    @ObservedObject var note: MarkdownNote

    func makeCoordinator() -> Coordinator { Coordinator(note: note) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.string = note.text
        note.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        note.textView = view
        // Only an outside change (such as a restored backup) differs from the view; typing already matches.
        if view.string != note.text { view.string = note.text }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let note: MarkdownNote
        init(note: MarkdownNote) { self.note = note }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, note.text != view.string else { return }
            note.text = view.string
        }
    }
}

struct MarkdownPreview: NSViewRepresentable {
    @ObservedObject var note: MarkdownNote

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== note.preview else { return }
        // Keep the reading position while the text is retyped.
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        view.document = note.preview
        if let pageIndex, let page = note.preview?.page(at: min(pageIndex, max(0, (note.preview?.pageCount ?? 1) - 1))) { view.go(to: page) }
    }
}
