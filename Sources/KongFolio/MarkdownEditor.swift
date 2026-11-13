import PDFKit
import SwiftUI

/// Editor on the left, typeset preview (the same A4 layout used when a Markdown file is opened) on the right.
struct MarkdownEditorView: View {
    @ObservedObject var note: MarkdownNote
    var store: WorkspaceStore? = nil
    var showsPrimaryToolbar = true
    @State private var showLayout = false
    @State private var showDisplay = false
    @State private var showPreviewSheet = false
    @State private var restoreSplitPreview = false
    @State private var focusedWriting = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if showsPrimaryToolbar { toolbar }
                if note.format == .markdown {
                    if !note.readOnly && !note.cleanEditing {
                        WritingToolbar(session:note.writingSession,prominent:true,markdownFile:note,
                                       showsControls:!focusedWriting,
                                       documentControls:AnyView(editorHeader(width:proxy.size.width)),
                                       compactMarkdown:proxy.size.width < 980)
                            .padding(.horizontal,proxy.size.width < 500 ? 10 : 20)
                            .padding(.vertical,8).background(.bar)
                    } else {
                        editorHeader(width:proxy.size.width)
                            .padding(.horizontal,16).padding(.vertical,8).background(.bar)
                    }
                } else {
                    editorHeader(width:proxy.size.width)
                        .padding(.horizontal,16).padding(.vertical,8).background(.bar)
                    if !note.readOnly {
                        WritingToolbar(session:note.writingSession,prominent:true,formatting:note.format != .plain)
                            .padding(.horizontal,16).padding(.vertical,4)
                    }
                }
                if note.saveConflict { SaveConflictBanner(copy: { note.save(asNew: true) }, reload: note.reloadAfterConflict,compare:{ note.editingTool = .merge }) }
                Divider()
                if note.format == .markdown && note.cleanEditing { CleanWritingView(note:note) }
                else { TextEditorPreviewSplit(note:note,allowsPreview:!focusedWriting && !showPreviewSheet) }
                Divider()
                HStack {
                    Text(note.status.isEmpty ? (note.fileURL?.path ?? "尚未保存到文件") : note.status).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let store { DocumentTaskButton(queue:store.documentTasks,store:store,onlyWhileRunning:true) }
                    if note.format == .markdown {
                        Text(note.readOnly ? "只读" : ".md").fixedSize().accessibilityLabel(note.readOnly ? "只读" : "Markdown 文件")
                    }
                    WritingCharacterCount(session:note.writingSession).lineLimit(1).fixedSize()
                }
                .font(.system(size:12)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(width: proxy.size.width)
        }
        .sheet(item:$note.editingTool) { tool in FileEditingSheet(note:note,tool:tool) }
        .sheet(isPresented:$showPreviewSheet,onDismiss:{
            note.showPreview = restoreSplitPreview
        }) {
            VStack(spacing:0) {
                HStack {
                    Label("排版预览",systemImage:"doc.richtext").font(.headline)
                    Spacer()
                    Button("完成") { showPreviewSheet = false }.keyboardShortcut(.cancelAction)
                }.padding()
                if !note.previewMessage.isEmpty {
                    Text(note.previewMessage).font(.caption).foregroundStyle(.orange).padding(8)
                } else if note.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("还没有可预览的内容",systemImage:"doc.text")
                } else if note.preview == nil {
                    ProgressView("正在生成预览…").frame(maxHeight:.infinity)
                } else {
                    MarkdownPreview(note:note)
                }
            }.adaptiveSheet(width:680,height:710,minimumWidth:360)
        }
        .sheet(isPresented:$showDisplay) { EditorDisplaySheet(note:note) }
        .sheet(isPresented: $showLayout) { TextLayoutSheet(note: note) }
        .sheet(isPresented: $note.showVersionHistory) { FileEditingSheet(note:note,tool:.history) }
        .alert("无法完成操作", isPresented: Binding(get: { note.error != nil }, set: { if !$0 { note.error = nil } })) {
            Button("好") { note.error = nil }
        } message: { Text(note.error ?? "") }
    }

    private func editorHeader(width:CGFloat)->some View {
        HStack(spacing:width < 500 ? 8 : 12) {
            VStack(alignment:.leading,spacing:3) {
                DraftNoteTitle(note:note)
                if width >= 650 {
                    Text(note.format.rawValue + (note.readOnly ? " · 只读" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(minWidth:40,maxWidth:.infinity,alignment:.leading).layoutPriority(-1)
            if note.format == .markdown, !focusedWriting {
                editorMode(width:width)
                Button {
                    let separate = width < LayoutMetrics.previewMinimum || note.cleanEditing
                    if separate {
                        restoreSplitPreview = note.showPreview
                        note.showPreview = true
                        showPreviewSheet = true
                    } else { note.showPreview.toggle() }
                } label: {
                    if width >= 1100 { Label("预览",systemImage:"rectangle.split.2x1") }
                    else { Image(systemName:"rectangle.split.2x1") }
                }
                .tint(note.showPreview ? .accentColor : nil)
                .help("查看排版预览").accessibilityLabel("排版预览")
            }
            if !showsPrimaryToolbar {
                Button { note.save() } label:{ Image(systemName:"square.and.arrow.down") }
                    .help("保存当前文件（⌘S）").accessibilityLabel("保存当前文件")
            }
            if !focusedWriting {
                Button { showDisplay = true } label:{ if width >= 1100 { Label("显示设置",systemImage:"textformat.size") } else { Image(systemName:"textformat.size") } }.help("编辑区字号、字体、行宽与间距；只影响屏幕显示").accessibilityLabel("编辑区显示设置")
                Menu {
                    if note.format == .markdown, !note.cleanEditing {
                        Button("专注写作") { focusedWriting = true }
                        Divider()
                    }
                    Button(note.readOnly ? "切换为编辑模式" : "切换为阅读模式") { note.toggleReadOnly() }
                    Button("插入图片…") { note.chooseImage() }.disabled(note.readOnly || note.format == .plain)
                    if note.format != .plain {
                        if note.format != .markdown { Toggle("显示右侧导出预览",isOn:$note.showPreview) }
                        Toggle("预览跟随正文段落",isOn:$note.followPreview)
                        Button("导出版式与预览设置…") { showLayout = true }
                    }
                    Divider()
                    ForEach(FileEditingTool.allCases) { tool in Button(tool.rawValue) { note.editingTool = tool }.disabled(note.format == .markdown && note.cleanEditing) }
                    Button("创建独立编辑副本…") { note.createEditingCopy() }
                } label:{ if width >= 1100 { Label("编辑选项",systemImage:"ellipsis") } else { Image(systemName:"ellipsis.circle") } }.menuStyle(.borderlessButton).fixedSize().help("编辑选项").accessibilityLabel("编辑选项")
            } else {
                Button("退出专注") { focusedWriting = false }.help("恢复 Markdown 工具栏")
            }
        }.controlSize(.regular).font(.system(size:13))
    }

    @ViewBuilder private func editorMode(width:CGFloat) -> some View {
        if width >= 980 {
            Picker("编辑方式",selection:Binding(get:{note.cleanEditing},set:setParagraphEditing)) {
                Text("正文").tag(false)
                Text("段落").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width:122)
                .accessibilityLabel("编辑方式").help("正文编辑完整 Markdown；段落模式逐段写作并显示图片")
        } else {
            Menu {
                Button("正文编辑") { setParagraphEditing(false) }
                Button("段落编辑") { setParagraphEditing(true) }
            } label: { Image(systemName:note.cleanEditing ? "text.alignleft" : "pencil") }
                .menuStyle(.borderlessButton).fixedSize()
                .help(note.cleanEditing ? "段落编辑" : "正文编辑").accessibilityLabel("编辑方式")
        }
    }

    private func setParagraphEditing(_ value:Bool) {
        guard note.textView?.hasMarkedText() != true,
              (NSApp?.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if note.cleanEditing != value { note.writingSession.endFind() }
        note.cleanEditing = value
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
        view.positionKey = note.fileURL.map{"text-file:"+ReadingProgress.canonicalPath($0.path)} ?? "markdown:"+note.id.uuidString; view.supportsMarkdownLists = note.format == .markdown;view.continuesMarkdownQuotes = note.format == .markdown;note.writingSession.view = view;view.writingSession = note.writingSession
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
        view.allowsMarkdownFormatting = note.format != .plain
        view.isRichText = false
        view.allowsUndo = true
        view.displayOptions = note.editorDisplay
        view.setAccessibilityLabel("文件正文编辑区")
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.string = note.text
        note.textView = view
        WritingPositions.shared.restore(view,key:view.positionKey)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NoteTextView else { return }
        note.textView = view
        view.displayOptions = note.editorDisplay
        view.isEditable = !note.readOnly
        view.allowsMarkdownFormatting = note.format != .plain
        view.supportsMarkdownLists = note.format == .markdown
        view.continuesMarkdownQuotes = note.format == .markdown
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
        note.lastFollowedDocument = nil;note.followSourceSelection()
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
