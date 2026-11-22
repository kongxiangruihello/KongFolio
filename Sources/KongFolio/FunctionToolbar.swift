import SwiftUI
import PDFKit

struct FunctionToolbar: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var issueInfo: ReaderShelfIssue?
    @AppStorage(ReaderToolbarProfile.key) private var profileData = Data()
    @State private var showToolbarSettings = false
    @State private var toolbarWidth: CGFloat = 800
    @State private var toolbarDrop: ReaderToolDropPosition?
    @State private var homeRecentFiles: [String] = []
    @AppStorage(LayoutKeys.sidebar) private var showNavigation = true
    @AppStorage(LayoutKeys.inspector) private var showInspector = true

    private var profile: ReaderToolbarProfile { ReaderToolbarProfile.decode(profileData) }
    private var workspace: Workspace? { store.commandWorkspace }
    private var context: ReaderToolbarContext {
        if store.activeNote != nil { return .text }
        return (workspace?.count ?? 0) > 0 ? .pdf : .empty
    }

    var body: some View {
        Group {
            if context == .empty {
                homeToolbar
            } else {
                documentToolbar
            }
        }
    }

    private var homeToolbar: some View {
        HStack(spacing: 8) {
            homeCreationButton("新建 Markdown", symbol: "doc", badge: "MD") { store.newNote() }
            homeCreationButton("新建文本", symbol: "doc.text") { store.newNote(format: .plain) }
            homeCreationButton("新建 PDF", symbol: "doc", badge: "PDF") { store.showPDFCreation = true }
            homeCreationButton("新建 HTML", symbol: "chevron.left.forwardslash.chevron.right") { store.newNote(format: .html) }
            ToolbarControlSurface {
                Menu {
                    if !homeRecentFiles.isEmpty {
                        ForEach(homeRecentFiles, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                store.openEach([URL(fileURLWithPath: path)])
                            }.help(path)
                        }
                    } else {
                        Text("暂无最近文件")
                    }
                } label: {
                    AppIcon("clock.arrow.circlepath").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("最近文件").accessibilityLabel("最近文件")
            }.frame(maxWidth: .infinity)
            ToolbarControlSurface {
                Menu {
                    Button("后台任务…") { store.showBackgroundJobs = true }
                    Button("启动恢复与阅读内存…") { store.showReadingSettings = true }
                    Button("检查更新…") { AppUpdateWindow.shared.show() }
                } label: {
                    AppIcon("ellipsis.circle").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("更多").accessibilityLabel("更多")
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .padding(.horizontal, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .background(.bar)
        .onAppear {
            let file = store.storage.appendingPathComponent("Recent.json")
            homeRecentFiles = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? []
        }
    }

    private func homeCreationButton(_ title: String, symbol: String, badge: String? = nil,
                                    action: @escaping () -> Void) -> some View {
        ToolbarControlSurface {
            Button(action: action) {
                ZStack {
                    AppIcon(symbol).font(.system(size: 22, weight: .regular))
                    if let badge {
                        Text(badge).font(.system(size: badge == "PDF" ? 6 : 8, weight: .bold))
                            .offset(y: 3)
                    }
                }.frame(width: 28, height: 28)
            }
            .help(title).accessibilityLabel(title)
        }.frame(maxWidth: .infinity)
    }

    private var documentToolbar: some View {
        GeometryReader { proxy in
            let showsQueue = context == .pdf && workspace?.id == store.shelfQueueReadingTab
            let issueWidth: CGFloat = issueInfo == nil ? 0 : 40
            let availableWidth = max(0,proxy.size.width-(showsQueue ? 40 : 0)-issueWidth)
            let visible = profile.visible(width:availableWidth,context:context)
            let overflow = profile.hidden(width:availableWidth,context:context)
            HStack(spacing:0) {
                if let workspace, context == .pdf {
                    PDFReaderPageControls(workspace: workspace).id(workspace.id)
                }
                ForEach(visible) { action in draggableTool(action) }
                if let issueInfo {
                    ToolbarControlSurface {
                        Menu {
                            ShelfIssueActions(info:issueInfo,store:store)
                        } label: { AppIcon("newspaper").frame(width:28,height:28) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .help(issueInfo.heading).accessibilityLabel("刊物期次")
                    }.frame(width:40)
                }
                if showsQueue {
                    ToolbarControlSurface {
                        Button { store.continueShelfQueue() } label:{
                            AppIcon("forward.end").frame(width:28,height:28)
                        }
                        .disabled(store.shelfQueueOpening || store.library.nextShelfQueueBook() == nil)
                        .help(store.library.nextShelfQueueBook() == nil ? "已到待读队列末尾" : "打开待读队列的下一份")
                        .accessibilityLabel("下一份待读文献")
                    }.frame(width:40)
                }
                ToolbarControlSurface {
                    Menu {
                        moreActions(overflow)
                    } label: {
                        AppIcon("ellipsis.circle").frame(width:28,height:28)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .help("更多工具").accessibilityLabel("更多工具")
                }
                .annotationToolsAnchor(when: overflow.contains(.annotate))
                .frame(maxWidth:visible.isEmpty ? nil : .infinity)
            }
            .coordinateSpace(name: ReaderToolFrames.space)
            .backgroundPreferenceValue(ReaderToolFrames.self) { frames in
                ReaderToolbarPointer(frames: frames, preview: { position in
                    if toolbarDrop != position { toolbarDrop = position }
                }, move: { source, position in
                    reorder(source, relativeTo: position.action, after: position.after, availableWidth: availableWidth)
                })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .font(.system(size:16,weight:.medium))
            .foregroundStyle(context == .pdf ? PDFToolbarPalette.graphite(colorScheme) : Color(nsColor: .secondaryLabelColor))
            .environment(\.toolbarIconTone, context == .pdf ? PDFToolbarPalette.graphite(colorScheme) : nil)
            .padding(.horizontal,12)
            .frame(maxWidth:CGFloat(visible.count+1)*128+(showsQueue ? 40 : 0)+issueWidth+(context == .pdf ? ReaderToolbarProfile.pageControlWidth : 0))
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:visible.isEmpty ? .trailing : .center)
            .onAppear { toolbarWidth = proxy.size.width }
            .onChange(of:proxy.size.width) { _,width in toolbarWidth = width }
        }.frame(height:44)
        .background(.bar)
        .task(id: context == .pdf ? workspace?.displayPath : nil) { refreshIssue() }
        .onReceive(store.library.$catalog.dropFirst()) { _ in
            Task { @MainActor in refreshIssue() }
        }
        .sheet(isPresented:$showToolbarSettings) {
            ReaderToolbarSettings(
                profile:Binding(get:{profile},set:{profileData = (try? JSONEncoder().encode($0)) ?? Data()}),
                width:toolbarWidth,context:context
            )
        }
        .popover(isPresented:$store.showQuickReadingNote) { QuickReadingNote(store:store) }
    }

    private func draggableTool(_ action: FileToolbarAction) -> some View {
        let selected = isSelected(action)
        let annotationActive = selected && action == .annotate
        return ToolbarControlSurface(selected: selected, annotationActive: annotationActive) {
            control(action, menu: false)
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .annotationToolsAnchor(when: action == .annotate)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { cell in
                Color.clear.preference(key: ReaderToolFrames.self, value: [
                    action: cell.frame(in: .named(ReaderToolFrames.space))
                ])
            }
        }
        .overlay(alignment: toolbarDrop?.after == true ? .trailing : .leading) {
            if toolbarDrop?.action == action {
                Capsule().fill(context == .pdf ? PDFToolbarPalette.graphite(colorScheme) : Color.accentColor).frame(width: 3, height: 28)
                    .allowsHitTesting(false)
            }
        }
    }

    private func reorder(_ source: FileToolbarAction, relativeTo target: FileToolbarAction, after: Bool, availableWidth: CGFloat) {
        var updated = profile
        let displayed = updated.visible(width: availableWidth, context: context)
        guard displayed.contains(source), displayed.contains(target),
              updated.move(source, relativeTo: target, after: after),
              let data = try? JSONEncoder().encode(updated) else { return }
        profileData = data
    }

    private func refreshIssue() {
        guard context == .pdf,let path = workspace?.displayPath else { issueInfo = nil;return }
        issueInfo = ReaderShelfIssue(books:store.library.books,path:path)
    }

    @ViewBuilder private func moreActions(_ overflow: [FileToolbarAction]) -> some View {
        Section("文件") {
            overflowControls(overflow,actions:[.newFile,.open,.save,.export])
            Button("在访达中浏览…") { store.browseFilesInFinder() }
            if store.canSave { Button("另存为…") { store.saveActive(asNew:true) } }
            if context == .pdf {
                overflowControls(overflow, actions: [.signature])
            } else {
                Button("签名管理…") { store.showSignatureManager = true }
            }
            Button("打印…") { store.printActive() }.disabled(!store.canSave)
            if context == .pdf, let workspace {
                Button("创建独立 PDF 编辑副本…") { workspace.createEditingCopy() }
            }
        }
        Section("阅读") {
            Button("最近批阅…") { store.showReadingBatch = true }
                .disabled(store.readingBatch == nil)
            Menu("搜索") {
                if overflow.contains(.search) { control(.search,menu:true) }
                Button("跨文件全文搜索…") { store.showFolderSearch = true }
            }
            overflowControls(overflow,actions:[.navigation,.pageThumbnails,.ocr,.zoom,.sidebar,.annotate,.pdfPages])
            let resources = overflow.filter { [.excerpt,.note,.library,.books].contains($0) }
            if !resources.isEmpty {
                Menu("阅读资料") { ForEach(resources) { control($0,menu:true) } }
            }
            Menu("左侧导航") { LeftPanelActions(store:store) }
            if context == .pdf, workspace?.progressPath != nil {
                Button("打开全部阅读资料…") { store.openReadingDesk(.search, window: true) }
            }
            if context == .pdf, let workspace {
                Button(workspace.readingLocked ? "切换为编辑模式" : "保护 PDF 正文") { workspace.toggleReadingLock() }
                Button(store.readingMode ? "切换到完整 PDF 工具界面" : "切换到专注阅读界面") { store.readingMode.toggle() }
            }
        }
        if let workspace, context != .text, overflow.contains(.tools) {
            PDFToolbarToolsMenu(workspace:workspace,store:store,showTitle:true,showPages:false,
                                showSignature:context == .empty && overflow.contains(.signature))
        }
        Section("应用") {
            overflowControls(overflow,actions:[.jobs])
            Button("阅读与史料辅助工具…") { store.showResearch = true }
            Button("排列与显示常用工具…") { showToolbarSettings = true }
            Button("启动恢复与阅读内存…") { store.showReadingSettings = true }
            Button("检查更新…") { AppUpdateWindow.shared.show() }
        }
    }

    @ViewBuilder private func overflowControls(_ overflow: [FileToolbarAction], actions: Set<FileToolbarAction>) -> some View {
        ForEach(overflow.filter { actions.contains($0) }) { action in
            if context.supports(action) || action == .export { control(action,menu:true) }
        }
    }

    @ViewBuilder private func control(_ action: FileToolbarAction, menu: Bool) -> some View {
        switch action {
        case .newFile:
            NewDocumentMenu(store:store,showTitle:menu)
        case .signature:
            if let workspace { SignatureToolbarMenu(workspace:workspace,showTitle:menu) }
        case .tools:
            if let workspace {
                PDFToolbarToolsMenu(workspace:workspace,store:store,showTitle:menu,
                                    showPages:!profile.visible(width:toolbarWidth,context:context).contains(.pdfPages),
                                    showSignature:context == .empty && !profile.visible(width:toolbarWidth,context:context).contains(.signature))
            }
        case .pageThumbnails:
            if let active = store.activeWorkspace {
                let title = active.showsPageThumbnails ? "返回 PDF 阅读" : "打开页面缩略图"
                Button { perform(action) } label: {
                    if menu { action.label(title) }
                    else { label(action, menu: false) }
                }
                .help(title)
                .accessibilityLabel(title)
                .disabled(unavailable(action))
            }
        case .ocr:
            if let workspace {
                Menu {
                    ocrActions(workspace)
                } label: {
                    if menu { label(action, menu: true) }
                    else { Text("OCR").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help(action.title).accessibilityLabel(action.title)
                .disabled(workspace.busy || workspace.readingLocked || workspace.drawingInProgress || workspace.placingSignature != nil)
            }
        case .zoom:
            if let workspace {
                Menu { PDFReaderZoomActions(workspace: workspace) } label: { label(action, menu: menu) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .help("缩放 PDF").accessibilityLabel("缩放 PDF")
            }
        case .excerpt:
            if menu || context != .pdf {
                Menu { ReadingExcerptActions(store:store) } label:{ label(action,menu:menu) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).help(action.menuTitle)
            } else if let workspace {
                HStack(spacing: 0) {
                    Button { workspace.quickPDFExcerpt() } label: { label(action, menu: false) }
                        .help(workspace.tool == .region ? "取消框选图片" : "摘录所选文字；未选文字时框选图片")
                        .accessibilityLabel(workspace.tool == .region ? "取消框选图片" : "摘录文字或图片")
                    Menu {
                        ReadingExcerptActions(store: store)
                    } label: { AppIcon("chevron.down").font(.system(size: 8)).frame(width: 14, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .help("摘录方式").accessibilityLabel("摘录方式")
                }.disabled(workspace.busy || workspace.showsPageThumbnails)
            }
        case .export:
            Menu {
                if context != .empty {
                    Text("当前文件")
                    Button("导出为 PDF…") { store.exportActive() }.disabled(!store.canSave)
                    Button("导出为 Word…") { store.exportWordActive() }.disabled(!store.canSave)
                    if let workspace = store.activeWorkspace {
                        Button("导出页面为图片…") { workspace.openImageExport() }.disabled(workspace.count == 0 || workspace.busy)
                    }
                    Divider()
                }
                Button("导出阅读资料…") { store.readingExportEssay = false; store.openReadingDesk(.exports,window:true) }
            } label:{ label(action,menu:menu) }.menuStyle(.borderlessButton).menuIndicator(.hidden).help(action.menuTitle)
        default:
            Button { perform(action) } label:{ label(action,menu:menu) }
                .help(action == .sidebar ? rightPanelTitle : action.menuTitle)
                .accessibilityLabel(action == .sidebar ? rightPanelTitle : action.title)
                .disabled(unavailable(action))
        }
    }

    private func isSelected(_ action: FileToolbarAction) -> Bool {
        switch action {
        case .sidebar: return store.rightReadingPanelVisible
        case .navigation: return showNavigation && !showInspector && workspace?.showsPageThumbnails != true
        case .pageThumbnails: return store.activeWorkspace?.showsPageThumbnails == true
        case .annotate:
            guard let workspace else { return false }
            return workspace.showAnnotationBar && !workspace.showsPageThumbnails && !workspace.readingLocked
        case .excerpt: return context == .pdf && workspace?.tool == .region
        case .search: return store.rightPDFSearchWorkspace != nil
        case .pdfPages: return store.activeWorkspace?.pageEditing053 == true
        default: return false
        }
    }

    private var rightPanelTitle: String { store.rightReadingPanelVisible ? "收起右侧面板" : "打开右侧面板" }

    @ViewBuilder private func label(_ action: FileToolbarAction, menu: Bool) -> some View {
        if menu { action.label(action == .sidebar ? rightPanelTitle : action.menuTitle) }
        else { action.icon.frame(width:28,height:28) }
    }

    private func unavailable(_ action: FileToolbarAction) -> Bool {
        switch action {
        case .search: return !store.canSearchPDF
        case .pdfPages: return (store.activeWorkspace?.count ?? 0) == 0
        case .pageThumbnails:
            guard let active = store.activeWorkspace else { return true }
            return active.busy || active.placingSignature != nil || active.drawingInProgress
        case .save: return !store.canSave
        case .annotate: return context != .pdf || workspace?.readingLocked == true
        default: return false
        }
    }

    @ViewBuilder private func ocrActions(_ workspace: Workspace) -> some View {
        Button("识别当前页") { workspace.ocrCurrentPage() }
        Button("识别选中页面（\(workspace.effectivePages.count) 页）") {
            workspace.ocr(selectedOnly: true)
        }.disabled(workspace.effectivePages.isEmpty)
        Button("识别整份 PDF") { workspace.ocr() }
        Divider()
        Button("OCR 质量检查…") { workspace.openOCRQuality() }
        Button("OCR 批量纠错…") { workspace.showOCRBatchCorrection = true }
    }

    private func perform(_ action: FileToolbarAction) {
        switch action {
        case .search: store.openPDFSearch()
        case .pdfPages:
            store.activeWorkspace?.showsPageThumbnails = false
            store.activeWorkspace?.pageEditing053 = true
        case .navigation:
            let alreadyOpen = showNavigation && !showInspector && store.activeWorkspace?.showsPageThumbnails != true
            store.activeWorkspace?.showsPageThumbnails = false
            store.activeWorkspace?.pageEditing053 = false
            showInspector = false
            showNavigation = !alreadyOpen
        case .pageThumbnails:
            guard let active = store.activeWorkspace else { return }
            if !active.showsPageThumbnails {
                store.focus(active)
                active.captureReadingPosition()
                active.pdfView?.clearSelection()
                active.pdfView?.window?.makeFirstResponder(nil)
                store.closeRightReadingPanel()
            }
            active.showsPageThumbnails.toggle()
        case .open: store.open()
        case .library:
            if context == .pdf, workspace?.progressPath != nil { store.openCurrentBookNotebook() }
            else { store.openReadingDesk(.search,window:true) }
        case .note:
            if let workspace, !workspace.showsPageThumbnails, let selection = workspace.pdfView?.currentSelection,
               let excerpt = workspace.readingExcerpt(from: selection, trackVisual: false) {
                store.startNoteFromExcerpt(excerpt)
            } else { store.newReadingNote() }
        case .annotate:
            workspace?.toggleQuickAnnotationTools()
        case .save: store.saveActive()
        case .books: store.openReadingHistory(.bookshelf)
        case .jobs: store.showBackgroundJobs = true
        case .sidebar: store.toggleRightReadingPanel()
        default: break
        }
    }
}

private struct ToolbarControlSurface<Content: View>: View {
    var selected = false
    var annotationActive = false
    @Environment(\.toolbarIconTone) private var toolbarIconTone
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        content()
            .frame(width:34,height:32)
            .foregroundStyle(annotationActive ? Color.white : toolbarIconTone ?? Color(nsColor: .secondaryLabelColor))
            .environment(\.toolbarIconTone, annotationActive ? Color.white : toolbarIconTone)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(annotationActive ? PDFToolbarPalette.annotationHighlight : Color.primary.opacity(selected ? 0.11 : hovered ? 0.07 : 0))
            }
            .onHover { hovered = $0 }
    }
}

private struct PDFToolbarToolsMenu: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: WorkspaceStore
    @State private var issueInfo: ReaderShelfIssue?
    let showTitle: Bool
    let showPages: Bool
    let showSignature: Bool

    private var hasPDF: Bool { workspace.count > 0 }
    private var canEditPDF: Bool { hasPDF && !workspace.readingLocked && !workspace.busy }

    var body: some View {
        Menu {
            PDFPageToolButtons(workspace: workspace)
            Divider()
            Menu("页面编辑") {
                if showPages {
                    Button("编辑 PDF 页面") {
                        store.activeWorkspace?.showsPageThumbnails = false
                        store.activeWorkspace?.pageEditing053 = true
                    }.disabled(!hasPDF)
                }
                Button("合并 PDF…") { workspace.open(insert:hasPDF,merge:!hasPDF) }.disabled(workspace.readingLocked || workspace.busy)
                Button("对照阅读…") { workspace.compare() }.disabled(!hasPDF || workspace.busy)
            }
            Menu("压缩与转换") {
                Button("压缩 PDF…") { workspace.compress() }
                Button("导出 Word…") { store.exportWordActive() }
                Button("提取表格…") { workspace.showTableExtraction = true }
                Button("填写 PDF 表单…") { workspace.showPDFForms = true }
            }.disabled(!canEditPDF)
            if showSignature { SignatureToolbarMenu(workspace:workspace,showTitle:true) }
            Button("打开 PDF 工具窗口…") { workspace.showTools = true }.disabled(workspace.readingLocked)
        } label: {
            if showTitle { Label("PDF 工具",appIcon:"square.grid.2x2") }
            else { AppIcon("square.grid.2x2").frame(width:28,height:28) }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("PDF 工具：拆分、裁剪、清除空白边、压缩与转换").accessibilityLabel("PDF 工具")
    }
}
