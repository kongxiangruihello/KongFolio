import SwiftUI

struct FunctionToolbar: View {
    @ObservedObject var store: WorkspaceStore
    @AppStorage(ReaderToolbarProfile.key) private var profileData = Data()
    @State private var showToolbarSettings = false
    @State private var toolbarWidth: CGFloat = 800

    private var profile: ReaderToolbarProfile { ReaderToolbarProfile.decode(profileData) }
    private var workspace: Workspace? { store.commandWorkspace }
    private var context: ReaderToolbarContext {
        if store.activeNote != nil { return .text }
        return (workspace?.count ?? 0) > 0 ? .pdf : .empty
    }

    var body: some View {
        GeometryReader { proxy in
            let visible = profile.visible(width:proxy.size.width,context:context)
            let overflow = profile.hidden(width:proxy.size.width,context:context)
            HStack(spacing:4) {
                ForEach(visible) { action in
                    if profile.order == ReaderToolbarProfile().order && action != visible.first &&
                        ((context == .pdf && action == .search) || action == .export) {
                        Divider().frame(height:16)
                    }
                    control(action,menu:false).frame(width:32)
                }
                Menu {
                    moreActions(overflow)
                } label: {
                    Image(systemName:"ellipsis.circle").frame(width:28,height:28)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).help("更多工具").accessibilityLabel("更多工具")
                Spacer(minLength:0)
            }
            .buttonStyle(.borderless).font(.system(size:16)).padding(.horizontal,12).frame(height:44).clipped()
            .onAppear { toolbarWidth = proxy.size.width }
            .onChange(of:proxy.size.width) { _,width in toolbarWidth = width }
        }.frame(height:44)
        .sheet(isPresented:$showToolbarSettings) {
            ReaderToolbarSettings(
                profile:Binding(get:{profile},set:{profileData = (try? JSONEncoder().encode($0)) ?? Data()}),
                width:toolbarWidth,context:context
            )
        }
        .popover(isPresented:$store.showQuickReadingNote) { QuickReadingNote(store:store) }
    }

    @ViewBuilder private func moreActions(_ overflow: [FileToolbarAction]) -> some View {
        Section("文件") {
            overflowControls(overflow,actions:[.newFile,.open,.save,.export])
            if store.canSave { Button("另存为…") { store.saveActive(asNew:true) } }
            Button("打印…") { store.printActive() }.disabled(!store.canSave)
            if context == .pdf, let workspace {
                Button("创建独立 PDF 编辑副本…") { workspace.createEditingCopy() }
            }
        }
        Section("阅读") {
            Menu("搜索") {
                if overflow.contains(.search) { control(.search,menu:true) }
                Button("跨文件全文搜索…") { store.showFolderSearch = true }
            }
            overflowControls(overflow,actions:[.sidebar,.annotate])
            let resources = overflow.filter { [.excerpt,.note,.library,.books].contains($0) }
            if !resources.isEmpty {
                Menu("阅读资料") { ForEach(resources) { control($0,menu:true) } }
            }
            Menu("左侧导航") { LeftPanelActions(store:store) }
            if context == .pdf, let workspace {
                Button(workspace.readingLocked ? "切换为编辑模式" : "保护 PDF 正文") { workspace.toggleReadingLock() }
                Button(store.readingMode ? "切换到完整 PDF 工具界面" : "切换到专注阅读界面") { store.readingMode.toggle() }
            }
        }
        if let workspace, context != .text, overflow.contains(.tools) {
            PDFToolbarToolsMenu(workspace:workspace,store:store,showTitle:true,showPages:overflow.contains(.pdfPages),
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
        case .excerpt:
            Menu { ReadingExcerptActions(store:store) } label:{ label(action,menu:menu) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).help(action.menuTitle)
        case .export:
            Menu {
                if context != .empty { Button("当前文件导出 PDF…") { store.exportActive() }.disabled(!store.canSave) }
                if context == .text { Button("当前文件导出 Word…") { store.exportWordActive() } }
                Button("阅读记录与笔记…") { store.readingExportEssay = false; store.openReadingDesk(.exports,window:true) }
            } label:{ label(action,menu:menu) }.menuStyle(.borderlessButton).menuIndicator(.hidden).help(action.menuTitle)
        default:
            Button { perform(action) } label:{ label(action,menu:menu) }
                .foregroundStyle(action == .sidebar && store.rightReadingPanelVisible ? Color.accentColor : Color.primary)
                .help(action == .sidebar ? rightPanelTitle : action.menuTitle)
                .accessibilityLabel(action == .sidebar ? rightPanelTitle : action.title)
                .disabled(unavailable(action))
        }
    }

    private var rightPanelTitle: String { store.rightReadingPanelVisible ? "收起右侧面板" : "打开右侧面板" }

    @ViewBuilder private func label(_ action: FileToolbarAction, menu: Bool) -> some View {
        if menu { Label(action == .sidebar ? rightPanelTitle : action.menuTitle,systemImage:action.symbol) }
        else { Image(systemName:action.symbol).frame(width:28,height:28) }
    }

    private func unavailable(_ action: FileToolbarAction) -> Bool {
        switch action {
        case .search: return !store.canSearchPDF
        case .pdfPages: return (store.activeWorkspace?.count ?? 0) == 0
        case .save: return !store.canSave
        case .annotate: return context != .pdf || workspace?.readingLocked == true
        default: return false
        }
    }

    private func perform(_ action: FileToolbarAction) {
        switch action {
        case .search: store.openPDFSearch()
        case .pdfPages: store.activeWorkspace?.pageEditing053 = true
        case .open: store.open()
        case .library: store.openReadingDesk(.search,window:true)
        case .note: store.newReadingNote()
        case .annotate: workspace?.showAnnotationBar.toggle()
        case .save: store.saveActive()
        case .books: store.showReadingHistory = true
        case .jobs: store.showBackgroundJobs = true
        case .sidebar: store.toggleRightReadingPanel()
        default: break
        }
    }
}

private struct PDFToolbarToolsMenu: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: WorkspaceStore
    let showTitle: Bool
    let showPages: Bool
    let showSignature: Bool

    private var hasPDF: Bool { workspace.count > 0 }
    private var canEditPDF: Bool { hasPDF && !workspace.readingLocked && !workspace.busy }

    var body: some View {
        Menu {
            Menu("页面编辑") {
                if showPages {
                    Button("编辑 PDF 页面") { store.activeWorkspace?.pageEditing053 = true }.disabled(!hasPDF)
                }
                Button("合并 PDF…") { workspace.open(insert:hasPDF,merge:!hasPDF) }.disabled(workspace.readingLocked || workspace.busy)
                Button("对照阅读…") { workspace.compare() }.disabled(!hasPDF || workspace.busy)
            }
            Menu("OCR") {
                Button("识别正文") { workspace.ocr() }
                Button("OCR 质量检查…") { workspace.openOCRQuality() }
                Button("OCR 批量纠错…") { workspace.showOCRBatchCorrection = true }
            }.disabled(!canEditPDF)
            Menu("压缩与转换") {
                Button("压缩 PDF…") { workspace.compress() }
                Button("导出 Word…") { store.exportWordActive() }
                Button("提取表格…") { workspace.showTableExtraction = true }
                Button("填写 PDF 表单…") { workspace.showPDFForms = true }
            }.disabled(!canEditPDF)
            if showSignature { SignatureToolbarMenu(workspace:workspace,showTitle:true) }
            Button("打开 PDF 工具窗口…") { workspace.showTools = true }.disabled(workspace.readingLocked)
        } label: {
            if showTitle { Label("PDF 工具",systemImage:"square.grid.2x2") }
            else { Image(systemName:"square.grid.2x2").frame(width:28,height:28) }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("PDF 工具：页面编辑、OCR、压缩与转换").accessibilityLabel("PDF 工具")
    }
}
