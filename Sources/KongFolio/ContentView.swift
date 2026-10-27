import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var comparisonSync = ComparisonSync()
    @State private var showSignatureImport = false
    @State private var showToolbarSettings = false
    @State private var pageDropTarget: Int?
    @AppStorage(ToolbarPreferences.key) private var toolbarSaved = ""
    @AppStorage(LayoutKeys.sidebar) private var showSidebar = true
    @AppStorage(LayoutKeys.inspector) private var showInspector = true
    @AppStorage(LayoutKeys.board) private var showBoard = false

    var body: some View {
        GeometryReader { proxy in layout(width: proxy.size.width) }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.accent)
        .disabled(workspace.busy)
        .overlay { if workspace.busy { busyOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            workspace.openDropped(files)
            return true
        }
        .alert("无法完成操作", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("好") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .sheet(isPresented: $showToolbarSettings) { ToolbarSettingsView(saved: $toolbarSaved) }
        .sheet(isPresented: $showSignatureImport) { SignatureImportSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showVersionHistory) { VersionHistoryView(workspace: workspace) }
        .sheet(isPresented: $workspace.showExport) { ExportSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showCompress) { CompressSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showScanWorkshop) { ScanWorkshop(workspace: workspace) }
        .sheet(isPresented: $workspace.showCrop) { CropSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showWordExport) { WordExportSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showBatch) { BatchSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showReplacementRules) { ReplacementRulesSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showOCRQuality) { OCRQualitySheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showOutlineText) { OutlineTextSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showOutlineCandidates) { OutlineCandidatesSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showPageInspection) { PageInspectionView(workspace: workspace) }
        .sheet(isPresented: $workspace.showOCRBatchCorrection) { OCRBatchCorrectionSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showOCRReview) { OCRReview(workspace: workspace) }
        .sheet(isPresented: $workspace.showProofreading) { ColumnProofView(workspace: workspace) }
        .sheet(isPresented: $workspace.showOutlineEditor) { OutlineEditorView(workspace: workspace) }
        .sheet(isPresented: $workspace.showProgress) { ReadingProgressSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showTools) { quickTools }
        .sheet(isPresented: $workspace.showImportOrder) { importOrder }
        .sheet(isPresented: Binding(get: { workspace.comparison != nil }, set: { if !$0 { workspace.comparison = nil } })) { comparisonSheet }
    }

    private func splitShown(width: CGFloat) -> Bool {
        workspace.splitPartner != nil && LayoutMetrics.showsSplit(width: width)
    }

    /// Lists the other open documents to read beside this one.
    private func splitMenu(iconOnly: Bool) -> some View {
        Menu {
            let candidates = workspace.store?.splitCandidates ?? []
            if candidates.isEmpty { Text("没有其他已打开的文档") }
            ForEach(candidates, id: \.id) { other in
                Button("与「\(other.displayName)」并排阅读") { workspace.store?.openSplit(with: other.id) }
            }
            if workspace.splitPartner != nil {
                Divider()
                Button("关闭并排阅读") { workspace.splitPartner = nil }
            }
        } label: {
            if iconOnly { Image(systemName: "rectangle.split.2x1") } else { Label("并排", systemImage: "rectangle.split.2x1") }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("把另一个已打开的文档放在右边，两份对照阅读")
    }

    private func boardShown(width: CGFloat) -> Bool {
        workspace.store != nil && LayoutMetrics.showsBoard(preferred: showBoard, width: width)
    }

    /// The window can be any size: panels and top bar controls adapt to the width (see `LayoutMetrics`).
    private func layout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar(width: width)
            Divider()
            HSplitView {
                if LayoutMetrics.showsSidebar(preferred: showSidebar, width: width) { sidebar.frame(minWidth: 140, idealWidth: 180, maxWidth: 230) }
                canvas.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                if splitShown(width: width), let partner = workspace.splitPartner {
                    SplitPane(primary: workspace, partner: partner) { workspace.splitPartner = nil }
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
                if boardShown(width: width), let board = workspace.store?.board { BoardView(board: board, workspace: workspace).frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity) }
                if LayoutMetrics.showsInspector(preferred: showInspector, width: width, boardShown: boardShown(width: width), splitShown: splitShown(width: width)) { inspector.frame(minWidth: 220, idealWidth: 290, maxWidth: 340) }
            }
            Divider()
            statusBar(width: width)
        }
        .frame(width: width)
    }

    private func statusBar(width: CGFloat) -> some View {
        HStack {
            Circle().fill(workspace.busy ? Color.orange : Color.green).frame(width: 6, height: 6)
            Text(workspace.pathHint ?? workspace.status).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if workspace.count > 0 {
                Text("\(workspace.selection + 1) / \(workspace.count) 页").lineLimit(1).fixedSize()
                if width >= 560, let page = workspace.page, let label = ReadingServices.pageLabel(page, index: workspace.selection) {
                    Text("印刷页码 \(label)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if width >= 760 { Text(workspace.recoveryStatus).foregroundStyle(.secondary).lineLimit(1) }
            if workspace.canRetry { Button("重试任务") { workspace.retryJob() } }
            if width >= 640 { Text("KongFolio \(AppInfo.version)").foregroundStyle(.tertiary).lineLimit(1) }
        }
        .font(.caption)
        .padding(.horizontal, width >= 640 ? 16 : 10)
        .padding(.vertical, 8)
    }

    private var busyOverlay: some View {
        VStack(spacing: 16) {
            ProgressView(workspace.taskLabel, value: workspace.progress, total: 1).frame(width: 260)
            if workspace.activeJob != nil || workspace.cancelAuxiliary != nil { Button("取消任务") { workspace.cancelJob() } }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var comparisonSheet: some View {
        VStack {
            HStack {
                Text("对照阅读").font(.headline)
                Toggle("同步翻页", isOn: $comparisonSync.enabled).toggleStyle(.switch)
                Spacer()
                Button("完成") { workspace.comparison = nil }
            }
            .padding()
            HSplitView {
                ComparisonCanvas(document: workspace.document, sync: comparisonSync)
                if let other = workspace.comparison { ComparisonCanvas(document: other, sync: comparisonSync) }
            }
        }
        .adaptiveSheet(width: 1040, height: 720)
        .onAppear { comparisonSync.page = workspace.selection }
    }

    private func topBar(width: CGFloat) -> some View {
        let style = LayoutMetrics.topBarStyle(width: width - 160 - CGFloat(max(0, ToolbarPreferences.decode(toolbarSaved).visible.count - 11)) * 70)
        let twoRows = width < 620
        let sidebarShown = LayoutMetrics.showsSidebar(preferred: showSidebar, width: width)
        let inspectorShown = LayoutMetrics.showsInspector(preferred: showInspector, width: width, boardShown: boardShown(width: width), splitShown: splitShown(width: width))
        let boardIsShown = boardShown(width: width)
        return VStack(spacing: 6) {
        HStack(spacing: style == .full ? 12 : 8) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .foregroundStyle(showSidebar && !sidebarShown ? .tertiary : .primary)
                .help(sidebarShown ? "隐藏左侧栏（⌥⌘1）" : (showSidebar ? "窗口太窄，放宽后显示左侧栏" : "显示左侧栏（⌥⌘1）"))
            if style != .minimal { Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(Brand.accent) }
            VStack(alignment: .leading, spacing: 2) {
                if style != .minimal { Text("KongFolio").font(.headline).lineLimit(1) }
                Text(workspace.displayName + (workspace.dirty && workspace.count > 0 ? " •" : "")).font(style == .minimal ? .callout : .caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(workspace.displayPath ?? "")
                    .contentShape(Rectangle())
                    .onHover { workspace.showPathHint($0) }
                    .contextMenu {
                        if workspace.displayPath != nil {
                            Button("拷贝完整路径") { workspace.copyPath() }
                            Button("在访达中显示") { workspace.revealInFinder() }
                        }
                    }
            }
            .frame(minWidth: 20, idealWidth: 175, maxWidth: style == .full ? 220 : 260, alignment: .leading)
            Spacer(minLength: 0)
            if style != .minimal {
                ForEach(ToolbarPreferences.decode(toolbarSaved).visible) { action in
                    toolbarAction(action, iconOnly: style != .full || ToolbarPreferences.decode(toolbarSaved).iconsOnly || action.isNewFile)
                }
            } else if !twoRows { compactToolbar }
            Button { showBoard.toggle() } label: { Image(systemName: "rectangle.3.group") }
                .buttonStyle(.borderless)
                .foregroundStyle(showBoard && !boardIsShown ? .tertiary : .primary)
                .help(boardIsShown ? "隐藏工作区（⌥⌘4）" : (showBoard ? "窗口太窄，放宽后显示工作区" : "显示工作区（⌥⌘4）：摘录、笔记和连线"))
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .foregroundStyle(showInspector && !inspectorShown ? .tertiary : .primary)
                .help(inspectorShown ? "隐藏右侧栏（⌥⌘2）" : (showInspector ? "窗口太窄，放宽后显示右侧栏" : "显示右侧栏（⌥⌘2）"))
        }
        if twoRows { compactToolbar.frame(maxWidth: .infinity, alignment: .leading) }

        }
        .contextMenu { Button("自定工具栏…") { showToolbarSettings = true } }
        .padding(style == .full ? 16 : 10)
    }

    private var compactToolbar: some View {
            HStack(spacing: 8) {
                ForEach(ToolbarPreferences.decode(toolbarSaved).visible.filter(\.isNewFile)) { action in toolbarAction(action, iconOnly: true) }
                annotateButton(iconOnly: true)
                toolsButton(iconOnly: true)
                Menu {
                    ForEach(ToolbarPreferences.decode(toolbarSaved).order.filter { !$0.isNewFile && !$0.pinned }) { action in
                        toolbarAction(action, iconOnly: false)
                    }
                    Divider()
                    Button("自定工具栏…") { showToolbarSettings = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("更多操作与自定工具栏")
            }.controlSize(.regular).frame(height: 30)
    }

    @ViewBuilder private func toolbarAction(_ action: ToolbarAction, iconOnly: Bool) -> some View {
        switch action {
        case .split: splitMenu(iconOnly: iconOnly)
        case .annotate: annotateButton(iconOnly: iconOnly)
        case .tools: toolsButton(iconOnly: iconOnly)
        case .open: openMenu(iconOnly: iconOnly)
        case .save: saveButton(iconOnly: iconOnly)
        case .close: closeButton(iconOnly: iconOnly)
        case .export: exportMenu(iconOnly: iconOnly)
        default:
            Button {
                switch action {
                case .newPDF: workspace.store?.newPDF()
                case .newMarkdown: workspace.store?.newNote()
                case .newText: workspace.store?.newNote(format: .plain)
                case .newHTML: workspace.store?.newNote(format: .html)
                case .ocr: workspace.ocr(selectedOnly: false)
                case .signature: showSignatureImport = true
                case .print: workspace.store?.printActive()
                default: break
                }
            } label: {
                if iconOnly { Image(systemName: action.symbol).frame(width: 28, height: 28) }
                else { Label(action.title, systemImage: action.symbol) }
            }.buttonStyle(.borderless).foregroundStyle(Brand.accent).help(action.title).accessibilityLabel(action.title)
                .disabled((action == .ocr || action == .print) && workspace.count == 0)
        }
    }

    /// Always in the top bar, so the annotation tools are one click away without being open on every document.
    @ViewBuilder private func annotateButton(iconOnly: Bool) -> some View {
        Button { workspace.showAnnotationBar.toggle() } label: {
            if iconOnly { Image(systemName: "pencil.tip.crop.circle") } else { Label("标注", systemImage: "pencil.tip.crop.circle") }
        }
        .accessibilityLabel("标注")
        .foregroundStyle(workspace.showAnnotationBar ? Brand.accent : Color.primary)
        .disabled(workspace.count == 0)
        .help(workspace.showAnnotationBar ? "收起标注工具栏（⌥⌘A）" : "打开标注工具栏（⌥⌘A）：画线、画框、写文字、荧光笔")
    }

    @ViewBuilder private func toolsButton(iconOnly: Bool) -> some View {
        Button { workspace.showTools = true } label: {
            if iconOnly { Image(systemName: "square.grid.2x2") } else { Label("快捷工具", systemImage: "square.grid.2x2") }
        }.help("快捷工具").accessibilityLabel("快捷工具")
    }

    @ViewBuilder private var openItems: some View {
        Button("打开文档或项目…（可多选，各占一个标签页）") { workspace.open() }
        Button("导入图片签名…") { showSignatureImport = true }
        Button("合并多个文件为一个文档…") { workspace.open(merge: true) }
        if !workspace.recentFiles.isEmpty {
            Divider()
            ForEach(workspace.recentFiles, id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) { workspace.load([URL(fileURLWithPath: path)]) }.help(path)
            }
        }
    }

    private func openMenu(iconOnly: Bool) -> some View {
        Menu { openItems } label: {
            if iconOnly { Image(systemName: "folder") } else { Label("打开", systemImage: "folder") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("打开文件")
    }

    @ViewBuilder private func saveButton(iconOnly: Bool) -> some View {
        Button { workspace.saveDirectly() } label: {
            if iconOnly { Image(systemName: "square.and.arrow.down") } else { Text("保存") }
        }
        .disabled(workspace.count == 0).help("保存当前文件（⌘S）；已有 PDF 自动保存标注")
    }

    @ViewBuilder private func closeButton(iconOnly: Bool) -> some View {
        Button { workspace.closeTab() } label: {
            if iconOnly { Image(systemName: "xmark.circle") } else { Text("关闭") }
        }
        .disabled(workspace.count == 0 || workspace.busy).help("关闭当前文档（⇧⌘W）")
    }

    @ViewBuilder private var exportItems: some View {
        Button("KongFolio 项目…（含标注、识别、目录，可再次打开）") { workspace.saveProject(asNew: true) }
        Divider()
        Button("PDF · 全部页面") { workspace.exportPDF() }
        Button("PDF · 固化标注，可附摘要页…") { workspace.openExport(format: .pdf, scope: .all, pdfMode: .flatten) }
        Button("PDF · 提取选中页") { workspace.exportPDF(currentOnly: true) }
        Button("PDF · 压缩体积…") { workspace.compress() }
        Divider()
        Button("Word（.docx）· 文字与页面…") { workspace.openWordExport() }
        Button("保存历史与恢复…") { workspace.showVersionHistory = true }.disabled(workspace.historySource == nil)
        Button("任务中心与扫描配方…") { workspace.showBatch = true }
        Button("TXT") { workspace.exportText(markdown: false) }
        Button("Markdown · 全文") { workspace.exportText(markdown: true) }
        Button("Markdown · 摘录与笔记") { workspace.exportNotes() }
        Divider()
        Button("笔记大纲 · Word（按目录分章）…") { workspace.exportNotesOutline(.word) }
        Button("笔记大纲 · Markdown…") { workspace.exportNotesOutline(.markdown) }
        Button("笔记大纲 · 文本…") { workspace.exportNotesOutline(.text) }
        Button("笔记大纲 · 整理后导出（排序、标签、合并重复）…") { workspace.showOutlineEditor = true }
        Divider()
        Button("PDF · 干净副本（不含任何标注）…") { workspace.exportAnnotationPDF(.clean) }
        Button("PDF · 含标注，末尾附批注清单…") { workspace.exportAnnotationPDF(.annotatedWithList) }
        Button("PDF · 批注清单（单独一份）…") { workspace.exportAnnotationPDF(.listOnly) }
        Button("PDF · 只含列表当前筛选的标注…") { workspace.exportAnnotationPDF(.filtered) }
    }

    private func exportMenu(iconOnly: Bool) -> some View {
        Menu { exportItems } label: {
            if iconOnly { Image(systemName: "square.and.arrow.up") } else { Label("导出", systemImage: "square.and.arrow.up") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(workspace.count == 0)
        .help("导出")
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            Picker("导航", selection: $workspace.sidebarTab) {
                ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            if workspace.sidebarTab == .pages { pagesSidebar } else { ReadingSidebar(workspace: workspace) }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var pagesSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("页面").font(.headline); Spacer(); Text("\(workspace.count)").foregroundStyle(.secondary) }
                .padding(.horizontal, 14).padding(.top, 16)
            Text("⌘ 多选 · ⇧ 连选 · 可拖至其他标签页").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14)
            ScrollViewReader { proxy in
                List(selection:Binding(get:{workspace.selectedPages},set:{workspace.selectSidebarPages($0)})) {
                    ForEach(0..<workspace.count, id: \.self) { index in
                        Button { workspace.selectPage(index, modifiers: NSEvent.modifierFlags) } label: {
                            VStack(spacing: 6) {
                                ThumbnailView(workspace: workspace, index: index)
                                Text(thumbnailCaption(index)).font(.caption).monospacedDigit()
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(workspace.selectedPages.contains(index) ? Brand.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(index+1) 页")
                        .tag(index)
                        .id(index)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top:6,leading:12,bottom:6,trailing:12))
                        .onDrag { NSItemProvider(object: workspace.pageDrag(index) as NSString) }
                        .onDrop(of: [.utf8PlainText], delegate: PageDropDelegate(workspace: workspace, insertion: index, targeted: { targeted in pageDropTarget = targeted ? index : (pageDropTarget == index ? nil : pageDropTarget) }))
                        .overlay(alignment: .top) { if pageDropTarget == index { Rectangle().fill(Brand.accent).frame(height: 3) } }
                    }
                }
                .listStyle(.plain)
                .onChange(of:workspace.selection) { _,page in proxy.scrollTo(page,anchor:.center) }
                .task(id:workspace.layoutRevision) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(workspace.selection,anchor:.center)
                }
            }
            HStack {
                Button { workspace.move(-1) } label: { Image(systemName: "arrow.up") }.disabled(workspace.effectivePages.first == 0)
                Button { workspace.move(1) } label: { Image(systemName: "arrow.down") }.disabled(workspace.effectivePages.last == workspace.count - 1)
                Spacer()
                Button { workspace.open(insert: true) } label: { Image(systemName: "plus") }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func thumbnailCaption(_ index: Int) -> String {
        guard let page = workspace.document.page(at: index), let label = ReadingServices.pageLabel(page, index: index) else { return "\(index + 1)" }
        return "\(index + 1) · p.\(label)"
    }

    @ViewBuilder private var canvas: some View {
        if workspace.count == 0, workspace.displayPath != nil {
            // A tab whose file has not been read yet (opened with many others, restored, or released to save memory).
            VStack(spacing: 14) {
                Image(systemName: "doc.richtext").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Brand.accent)
                Text(workspace.displayName).font(.title3.weight(.medium))
                Text(workspace.displayPath ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if workspace.busy { Text("正在读取…").foregroundStyle(.secondary) }
                else { Button("读取这个文件") { workspace.needsLoad = true; workspace.ensureLoaded() }.buttonStyle(.borderedProminent) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.count == 0 {
            VStack(spacing: 20) {
                Image(systemName: "doc.richtext").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Brand.accent)
                Text("每一页，都井井有条。").font(.system(size: 28, weight: .medium))
                Text("PDF 与文本文档的阅读、批注、整理工作台").foregroundStyle(.secondary)
                Button("打开文档…") { workspace.open() }.buttonStyle(.borderedProminent).controlSize(.large)
                Text("PDF · 图片 · Markdown · HTML · TXT · 可直接拖入窗口").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PDFCanvas(workspace: workspace)
                .overlay(alignment: .top) {
                    if workspace.showAnnotationBar {
                        GeometryReader { proxy in
                            AnnotationBar(workspace: workspace, availableWidth: max(140, proxy.size.width - 20))
                                .padding(.horizontal, 10).padding(.top, 10)
                        }
                    }
                }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("文档属性").font(.headline)
                HStack {
                    Button { workspace.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(!workspace.canUndo)
                    Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!workspace.canRedo)
                }
                documentControls
                Divider()
                ocrControls
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .disabled(workspace.count == 0)
    }

    private var ocrControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("空白页与重复页检查…") { workspace.showPageInspection = true }.disabled(workspace.count == 0)
            Text("文本识别（本地 Vision）").font(.subheadline.bold())
            Picker("语言", selection: Binding(get: { workspace.ocrSettings.presetID }, set: { id in
                if let preset = OCRSettings.presets.first(where: { $0.id == id }) { workspace.ocrSettings.languages = preset.languages }
            })) {
                ForEach(OCRSettings.presets) { Text($0.title).tag($0.id) }
            }
            Picker("渲染精度", selection: $workspace.ocrSettings.dpi) {
                ForEach(OCRSettings.dpiChoices, id: \.self) { Text("\($0) DPI").tag($0) }
            }
            Toggle("忽略红色印章和朱批", isOn: Binding(get: { workspace.ocrSettings.ignoresRedMarks }, set: { workspace.ocrSettings.ignoresRedMarks = $0 }))
            Toggle("忽略已有的文字层，整页重新识别", isOn: Binding(get: { workspace.ocrSettings.ignoresTextLayer }, set: { workspace.ocrSettings.ignoresTextLayer = $0 }))
            Text("有些扫描件（如汉王 OCR 处理过的）文字层里只有标题，程序会当作“已有文字”而跳过。遇到这种书请打开此项。原有的少量文字会留在页面里，导出时不受影响。").font(.caption).foregroundStyle(.secondary)
            Toggle("竖排（实验）", isOn: $workspace.ocrSettings.vertical)
            if workspace.ocrSettings.vertical {
                Text("按列从右到左切分，每列转成横行后识别，再逐字放回原位。适合字距清楚的刻本、排印本；夹注、双行小字和插图可能识别不全，请用“检查当前页区域”核对。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("识别全部") { workspace.ocr() }
                Button("识别选中页") { workspace.ocr(selectedOnly: true) }
                Button("继续识别") { workspace.ocr(resume: true) }.help("跳过已经识别过的页面，用于中断后接着做")
            }
            .disabled(workspace.count == 0)
            Text(workspace.ocrSettings.ignoresTextLayer ? "所有选定的页面都会被识别；原有标注会被固化，执行前会提示。" : "文字少于 \(workspace.ocrSettings.minimumTextCharacters) 个字符的页面会被识别；原有标注会被固化，执行前会提示。").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("检查当前页区域") { workspace.inspectOCR() }
                    Button("OCR 质量检查…") { workspace.openOCRQuality() }
                }
                Toggle("标出低置信度的列", isOn: Binding(get: { workspace.showLowConfidence }, set: { workspace.showLowConfidence = $0; workspace.refreshConfidenceMarks() }))
                Button("批量纠错…") { workspace.showOCRBatchCorrection = true }
                if workspace.meta(workspace.selection).ocrRegions != nil {
                    Button("对照校正…") { workspace.reviewSelection = -1; workspace.showOCRReview = true }
                }
                if ColumnProofreading.columns(workspace.meta(workspace.selection).ocrRegions ?? []) != nil {
                    Button("逐列校对…") { workspace.showProofreading = true }.help("竖排页：每一列的原图与识别文字上下对照，直接改字")
                }
            }
            Button("重新识别选中页") { workspace.ocr(selectedOnly: true, force: true) }
                .disabled(!workspace.effectivePages.allSatisfy { workspace.meta($0).ocrOriginal != nil })
            if !workspace.recognizedText.isEmpty {
                TextEditor(text: .constant(workspace.recognizedText)).font(.system(size: 11)).frame(height: 180)
            }
        }
    }

    private var documentControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("阅读布局", selection: $workspace.readingLayout) {
                ForEach(ReadingLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: workspace.readingLayout) { _, _ in workspace.scheduleRecovery() }
            HStack {
                Button("上一页") { workspace.selectPage(workspace.selection - 1) }.disabled(workspace.selection == 0)
                Button("下一页") { workspace.selectPage(workspace.selection + 1) }.disabled(workspace.selection >= workspace.count - 1)
                Button { workspace.addBookmark() } label: { Image(systemName: "bookmark") }
            }
            HStack {
                TextField("搜索文本（简繁通查）", text: $workspace.search).onSubmit { workspace.find() }
                Button { workspace.find() } label: { Image(systemName: "magnifyingglass") }
            }
            Divider()
            Text("页面管理 · 选中 \(workspace.effectivePages.count) 页").font(.subheadline.bold())
            HStack {
                TextField("页码：1–3, 5", text: $workspace.rangeText).onSubmit { workspace.selectRange() }
                Button("选取") { workspace.selectRange() }
            }
            HStack {
                Menu("选择页面") {
                    ForEach(PageSelectionKind.allCases) { kind in
                        Button(kind.rawValue) { workspace.selectPages(kind) }
                    }
                }.disabled(workspace.busy || workspace.count == 0)
                Button("复制选中页") { workspace.duplicatePages() }
            }
            HStack {
                Button("旋转 90°") { workspace.rotate() }
                Button("删除页面", role: .destructive) { workspace.remove() }.disabled(workspace.effectivePages.count >= workspace.count)
            }
            Menu("整理页序") {
                Button("反转选中页顺序") { workspace.reverseSelectedPages() }
                Button("还原双面扫描页序…") { workspace.restoreDuplexOrder() }
            }.disabled(workspace.busy || workspace.count < 2)
            Button("扫描整理：切分 / 纠偏 / 检查…") { workspace.showScanWorkshop = true }
            Button("裁边…") { workspace.openCrop() }
            Button("插入图片 / PDF…") { workspace.open(insert: true) }
            HStack {
                Button("提取选中页") { workspace.exportPDF(currentOnly: true) }
                Button("拆分选中页") { workspace.splitPages(selectedOnly: true) }
            }
            Divider()
            Text("摘录").font(.subheadline.bold())
            HStack {
                Picker("样式", selection: $workspace.markupStyle) { ForEach(MarkupStyle.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                Picker("颜色", selection: $workspace.markupColor) { ForEach(MarkupColor.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
            }
            Button("标记选中文字并附加笔记") { workspace.highlight() }
            Divider()
            Text("标注工具").font(.subheadline.bold())
            Picker("工具", selection: $workspace.tool) { ForEach(AnnotationTool.allCases) { Text($0.title).tag($0) } }.labelsHidden()
            TextField("批注 / 文字框 / 笔记内容", text: $workspace.note, axis: .vertical).lineLimit(3...5)
            ColorPicker("标注颜色", selection: $workspace.annotationColor, supportsOpacity: false)
            Toggle("在页面上方显示标注工具栏", isOn: $workspace.showAnnotationBar).font(.caption)
            if [.pen, .line, .arrow, .rectangle, .ellipse].contains(workspace.tool) {
                HStack {
                    Text("线宽 \(workspace.penWidth, format: .number.precision(.fractionLength(1)))")
                    Slider(value: $workspace.penWidth, in: 0.5...12)
                }
                .font(.caption)
                if workspace.tool == .pen { Toggle("荧光笔（宽、半透明）", isOn: $workspace.penHighlighter).font(.caption) }
            }
            if workspace.selectedAnnotation != nil {
                HStack { Button("更新标注") { workspace.updateAnnotation() }; Button("删除标注") { workspace.deleteAnnotation() } }
                HStack { Button("缩小") { workspace.resizeAnnotation(0.85) }; Button("放大") { workspace.resizeAnnotation(1.15) } }
            }
            if !workspace.currentAnnotations.isEmpty {
                DisclosureGroup("当前页标注（\(workspace.currentAnnotations.count)）") {
                    ForEach(Array(workspace.currentAnnotations.enumerated()), id: \.offset) { index, annotation in
                        Button { workspace.tool = .edit; workspace.selectAnnotation(annotation) } label: {
                            HStack {
                                Image(systemName: workspace.selectedAnnotation === annotation ? "checkmark.circle.fill" : "circle")
                                Text("\(index + 1). \(annotation.contents?.prefix(24) ?? Substring(annotation.type ?? "标注"))").lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
            DisclosureGroup("本地签名库") {
                Button("导入图片签名…") { showSignatureImport = true }
                Button("保存本页手写签名") { workspace.saveSignature() }
                ForEach(workspace.signatures) { template in
                    HStack {
                        SignatureThumbnail(template: template)
                        Button(template.name) { workspace.beginPlacing(template) }.buttonStyle(.plain).lineLimit(1)
                        Spacer()
                        Menu {
                            ForEach(workspace.allSignaturePositions) { position in
                                Button(position.name) { workspace.placeSignature(template, at: position) }
                            }
                        } label: { Image(systemName: "scope") }
                        .menuStyle(.borderlessButton).fixedSize().help("放到已记住的位置")
                        Button { workspace.removeSignature(template.id) } label: { Image(systemName: "trash") }
                    }
                }
            }
            if workspace.placingSignature != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("正在放置签名").font(.headline)
                    HStack {
                        Text("大小")
                        Slider(value: Binding(get: { workspace.signatureWidth }, set: { workspace.setSignatureWidth($0) }), in: 0.08...0.8)
                    }
                    Menu("位置模板") {
                        ForEach(workspace.allSignaturePositions) { position in
                            Button(position.name) { if let template = workspace.placingSignature { workspace.placeSignature(template, at: position) } }
                        }
                        Divider()
                        Menu("记住当前位置为") {
                            ForEach(SignaturePosition.Page.allCases, id: \.self) { page in
                                Button(page.label) { workspace.rememberSignaturePosition(as: page) }
                            }
                        }
                        if !workspace.signaturePositions.isEmpty {
                            Menu("删除位置") {
                                ForEach(workspace.signaturePositions) { position in
                                    Button(position.name) { workspace.removeSignaturePosition(position.id) }
                                }
                            }
                        }
                    }
                    HStack {
                        Button("放置到页面") { workspace.confirmSignaturePlacement() }
                        Button("取消") { workspace.cancelSignaturePlacement() }
                    }
                    Text("拖动移动，拖蓝色角调整大小；双击或回车确认。放置后可用撤销。").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            }
            Text("点击放置标注，拖动绘制；使用“编辑标注”选中并拖动位置，也可在列表中选择。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("−") { workspace.pdfView?.zoomOut(nil); workspace.captureReadingPosition() }
                Button("适合页面") { workspace.pdfView?.autoScales = true; workspace.readingScale = nil; workspace.captureReadingPosition() }
                Button("+") { workspace.pdfView?.zoomIn(nil); workspace.captureReadingPosition() }
            }
        }

    }

    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("快捷工具").font(.title2.bold())
                Spacer()
                Button("关闭") { workspace.showTools = false }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(QuickTool.allCases) { tool in
                    Button { workspace.quick(tool) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tool.rawValue).font(.headline)
                            Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .padding(12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(workspace.count == 0 && !tool.availableWithoutDocument)
                }
            }
        }
        .padding(24)
        .frame(width: min(650, max(340, (NSApp.keyWindow?.contentView?.bounds.width ?? 650) - 20)))
    }

    private var importOrder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认合并顺序").font(.title2.bold())
            Text("使用上下按钮排列文件；每个文件内部保持原页序。").foregroundStyle(.secondary)
            List {
                ForEach(Array(workspace.pendingImports.enumerated()), id: \.offset) { index, url in
                    HStack {
                        Text("\(index + 1). \(url.lastPathComponent)")
                        Spacer()
                        Button("↑") { workspace.pendingImports.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("↓") { workspace.pendingImports.swapAt(index, index + 1) }.disabled(index == workspace.pendingImports.count - 1)
                    }
                }
            }
            .frame(height: 240)
            HStack {
                Button("取消") { workspace.showImportOrder = false; workspace.pendingImports = [] }
                Spacer()
                Button("开始合并") { workspace.finishImport() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .adaptiveSheet(width: 600, height: 520)
    }
}

/// Explicit providers also work on native macOS List rows, whose own drag handling can swallow Transferable strings.
@MainActor struct PageDropDelegate: DropDelegate {
    let workspace: Workspace
    var insertion: Int?
    var targeted: (Bool) -> Void = { _ in }
    func validateDrop(info: DropInfo) -> Bool { !workspace.busy && info.hasItemsConforming(to: [.utf8PlainText]) }
    func dropEntered(info: DropInfo) { targeted(true) }
    func dropExited(info: DropInfo) { targeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        targeted(false)
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            Task { @MainActor in
                if let insertion { _ = workspace.receivePageDrag(value, before: insertion) }
                else if let drag = PageDrag.decode(value), drag.source != workspace.id {
                    guard let store = workspace.store else { return }
                    store.select(workspace.id)
                    while workspace.busy {
                        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                        guard store.tabs.contains(where: { $0.id == workspace.id }) else { return }
                    }
                    guard workspace.count > 0 else { workspace.status = "目标文档无法读取，页面未传送"; return }
                    _ = store.preparePageTransfer(drag, to: workspace, at: min(workspace.count, workspace.selection + 1))
                }
            }
        }
        return true
    }
}
