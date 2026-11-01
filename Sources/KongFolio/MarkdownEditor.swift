import PDFKit
import SwiftUI

/// Editor on the left, typeset preview (the same A4 layout used when a Markdown file is opened) on the right.
struct MarkdownEditorView: View {
    @ObservedObject var note: MarkdownNote
    var store: WorkspaceStore? = nil
    var showsPrimaryToolbar = true
    @State private var showLayout = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if showsPrimaryToolbar { toolbar }
                HStack {
                    Button(note.readOnly ? "阅读模式 · 切换编辑" : "编辑模式 · 切换阅读") { note.toggleReadOnly() }.help("阅读模式保护正文，仍可选择和复制文字")
                    Menu("文件编辑") { ForEach(FileEditingTool.allCases) { tool in Button(tool.rawValue) { note.editingTool = tool } };Button("创建独立编辑副本…") { note.createEditingCopy() } }
                    if note.format != .plain { Toggle("预览",isOn:$note.showPreview).toggleStyle(.checkbox);Toggle("跟随段落",isOn:$note.followPreview).toggleStyle(.checkbox) }
                }.font(.caption).padding(.horizontal,10).padding(.vertical,4)
                if !note.readOnly { WritingToolbar(session:note.writingSession) }
                if note.saveConflict { SaveConflictBanner(copy: { note.save(asNew: true) }, reload: note.reloadAfterConflict,compare:{ note.editingTool = .merge }) }
                Divider()
                TextEditorPreviewSplit(note:note)
                Divider()
                HStack {
                    Text(note.status.isEmpty ? (note.fileURL?.path ?? "尚未保存到文件") : note.status).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    WritingCharacterCount(session:note.writingSession).lineLimit(1).fixedSize()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(width: proxy.size.width)
        }
        .sheet(item:$note.editingTool) { tool in FileEditingSheet(note:note,tool:tool) }
        .sheet(isPresented: $showLayout) { TextLayoutSheet(note: note) }
        .sheet(isPresented: $note.showVersionHistory) { FileEditingSheet(note:note,tool:.history) }
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
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(Brand.accent)
                Text("KongFolio").font(.headline)
                NewFileIcons(store: store)
            }
            Divider().frame(height: 18)
            Button("保存") { note.save() }.help("保存当前文件（⌘S）")
            Button("另存为…") { note.save(asNew: true) }
            Button { note.showVersionHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("查看和恢复文本文件的历史版本").disabled(note.fileURL == nil)
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
            Button { note.chooseImage() } label: { Image(systemName: "photo.badge.plus") }.help("插入本地图片（也可粘贴截图或拖入图片）").disabled(note.format == .plain)
            Button { note.insertTable() } label: { Image(systemName: "tablecells") }.help("插入表格").disabled(note.format == .plain)
            Button("排版…") { showLayout = true }.help("字体、行距与页边距；用于预览、导出和打印")
            Spacer()
            if note.format != .plain { Toggle("预览", isOn: $note.showPreview).toggleStyle(.switch).controlSize(.small) }
            Button("导出 Word…") { note.exportWord() }.help("导出为可编辑的 Word 文档（.docx）")
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
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.note = note
        view.positionKey = note.fileURL.map{"text-file:"+ReadingProgress.canonicalPath($0.path)} ?? "markdown:"+note.id.uuidString; view.supportsMarkdownLists = note.format == .markdown;note.writingSession.view = view;view.writingSession = note.writingSession
        view.minSize = NSSize(width: 0, height: 400); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.delegate = context.coordinator
        view.committed = { [weak coordinator = context.coordinator] in coordinator?.commit($0) }
        view.isEditable = !note.readOnly
        view.isRichText = false
        view.allowsUndo = true
        view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.string = note.text
        note.textView = view
        WritingPositions.shared.restore(view,key:view.positionKey)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NoteTextView else { return }
        note.textView = view
        view.isEditable = !note.readOnly
        let nextKey = note.fileURL.map{"text-file:"+ReadingProgress.canonicalPath($0.path)} ?? "markdown:"+note.id.uuidString
        if nextKey != view.positionKey { WritingPositions.shared.capture(view,key:view.positionKey);view.positionKey = nextKey;WritingRegistry.attach(view,key:nextKey);WritingPositions.shared.capture(view,key:nextKey) }
        view.minSize = NSSize(width: 0, height: max(1, scroll.contentSize.height))
        if view.frame.height < scroll.contentSize.height { view.setFrameSize(NSSize(width: scroll.contentSize.width, height: scroll.contentSize.height)) }
        // Only an outside change (such as a restored backup) differs from the view; typing already matches.
        context.coordinator.input.synchronize(view)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NSTextView else { return }
        (view as? ComposingTextView)?.finishEditingSession()
        view.delegate = nil
        if coordinator.note.textView === view { coordinator.note.textView = nil }
        if let view = view as? NoteTextView { view.note = nil }
        view.undoManager?.removeAllActions()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let note: MarkdownNote
        let input: StableInputCoordinator
        init(note: MarkdownNote) { self.note = note; input = StableInputCoordinator(read:{note.text},write:{note.text = $0}) }

        func textViewDidChangeSelection(_ notification:Notification) { if let view = notification.object as? ComposingTextView { WritingPositions.shared.capture(view,key:view.positionKey);note.followSourceSelection() } }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }; commit(view)
        }
        func commit(_ view:NSTextView) {
            input.publish(view)
        }
    }
}

struct MarkdownPreview: NSViewRepresentable {
    @ObservedObject var note: MarkdownNote

    func makeCoordinator()->Coordinator { Coordinator(note:note) }
    func makeNSView(context: Context) -> PDFView {
        let view = ManagedPDFView()
        note.previewView = view
        context.coordinator.observe(view)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stop();if coordinator.note.previewView === view { coordinator.note.previewView = nil }
        view.clearSelection(); view.delegate = nil; view.document = nil
    }

    func updateNSView(_ view: PDFView, context: Context) {
        note.previewView = view
        guard view.document !== note.preview else { return }
        // Keep the reading position while the text is retyped.
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        view.document = note.preview
        if let pageIndex, let page = note.preview?.page(at: min(pageIndex, max(0, (note.preview?.pageCount ?? 1) - 1))) { view.go(to: page) }
    }
    @MainActor final class Coordinator {
        let note:MarkdownNote;var observer:NSObjectProtocol?
        init(note:MarkdownNote) { self.note = note }
        func observe(_ view:PDFView) { observer = NotificationCenter.default.addObserver(forName:.PDFViewSelectionChanged,object:view,queue:.main) { [weak self] _ in MainActor.assumeIsolated { guard let self,self.note.followPreview else { return };self.note.locateSource(focus:false) } } }
        func stop() { if let observer { NotificationCenter.default.removeObserver(observer) };observer = nil }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

}
