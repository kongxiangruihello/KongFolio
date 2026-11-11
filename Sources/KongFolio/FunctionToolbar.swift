import SwiftUI

/// One fixed row. Every hidden control has the same action in the overflow menu.
struct FunctionToolbar: View {
    @ObservedObject var store:WorkspaceStore
    @State private var showLayout = false
    @State private var showToolbarSettings = false
    @AppStorage(ReaderToolbarProfile.key) private var profileData=Data()
    @State private var toolbarWidth:CGFloat=800
    private var profile:ReaderToolbarProfile { ReaderToolbarProfile.decode(profileData) }
    private var workspace:Workspace? { store.commandWorkspace }
    private var note:MarkdownNote? { store.activeNote }
    var body:some View {
        GeometryReader { proxy in
            HStack(spacing:4) {
                ForEach(profile.visible(width:proxy.size.width)) { action in control(action,menu:false).frame(minWidth:32,maxWidth:.infinity) }
                Button { if let note { note.toggleReadOnly() } else { workspace?.toggleReadingLock() } } label:{ Image(systemName:(note?.readOnly ?? workspace?.readingLocked ?? false) ? "lock" : "pencil") .frame(width:28,height:28) }.help((note?.readOnly ?? workspace?.readingLocked ?? false) ? "当前为阅读模式，点击切换编辑" : "当前为编辑模式，点击保护正文").disabled(note == nil && workspace == nil)
                Menu {
                    if !profile.hidden(width:proxy.size.width).isEmpty {
                        Section("工具栏收起的功能") { ForEach(profile.hidden(width:proxy.size.width)) { action in control(action,menu:true) } }
                    }
                    Section("右侧面板") { RightPanelActions(store:store) }
                    Section("左侧导航") { LeftPanelActions(store:store) }
                    Section("独立窗口与对话框") {
                        Button("跨文件全文搜索（对话框）…") { store.showFolderSearch = true }
                        Button("阅读与史料辅助工具（独立窗口）…") { store.showResearch = true }
                    }
                    Section("当前文件操作") {
                        if let note {
                            Menu("文件编辑（对话框）") { ForEach(FileEditingTool.allCases) { tool in Button(tool.rawValue) { note.editingTool = tool }.disabled(note.format == .markdown && note.cleanEditing) } }
                            Button("创建独立编辑副本…") { note.createEditingCopy() }
                            Button("另存文件…") { note.save(asNew:true) }
                            Button("插入图片…") { note.chooseImage() }.disabled(note.readOnly || note.format == .plain)
                            Button("导出版式与预览设置…") { showLayout = true }
                        } else if let workspace { Button("创建独立 PDF 编辑副本…") { workspace.createEditingCopy() } }
                        Button("打印…") { store.printActive() }
                    }
                    Section("界面与应用设置") {
                        Button("排列与显示常用工具…") { showToolbarSettings = true }
                        Button("启动恢复与阅读内存…") { store.showReadingSettings = true }
                        if workspace != nil { Button(store.readingMode ? "切换到完整 PDF 工具界面" : "切换到专注阅读界面") { store.readingMode.toggle() } }
                        Button("检查更新…") { AppUpdateWindow.shared.show() }
                    }
                } label:{Image(systemName:"ellipsis.circle").frame(width:28,height:28)}.menuStyle(.borderlessButton).menuIndicator(.hidden).help("更多：收起的工具、面板、文件操作和应用设置")
            }.buttonStyle(.borderless).font(.system(size:16)).padding(.horizontal,12).frame(height:44).clipped()
                .onAppear { toolbarWidth=proxy.size.width }
                .onChange(of:proxy.size.width) { _,width in toolbarWidth=width }
        }.frame(height:44)
        .sheet(isPresented:$showToolbarSettings) { ReaderToolbarSettings(profile:Binding(get:{profile},set:{profileData=(try? JSONEncoder().encode($0)) ?? Data()}),width:toolbarWidth) }
        .sheet(isPresented:$showLayout) { if let note { TextLayoutSheet(note:note) } }
        .popover(isPresented:$store.showQuickReadingNote) { QuickReadingNote(store:store) }
    }
    @ViewBuilder private func control(_ action:FileToolbarAction,menu:Bool)->some View {
        if action == .newFile {
            NewDocumentMenu(store:store,showTitle:menu)
        } else if action == .sidebar {
            Menu { RightPanelActions(store:store) } label:{label(action,menu:menu)}.menuStyle(.borderlessButton).menuIndicator(.hidden).help("右侧面板：搜索 PDF、摘录和笔记").accessibilityLabel("右侧面板")
        } else if action == .note {
            Button { store.newReadingNote() } label:{label(action,menu:menu)}.help(action.menuTitle)
        } else if action == .signature {
            if let workspace { SignatureToolbarMenu(workspace:workspace,showTitle:menu) }
            else { Button {} label:{label(action,menu:menu)}.disabled(true).help("打开 PDF 后导入或放置图片签名") }
        } else if action == .excerpt {
            Menu { ReadingExcerptActions(store:store) } label:{label(action,menu:menu)}.menuStyle(.borderlessButton).menuIndicator(.hidden).help(action.menuTitle)
        } else if action == .export {
            Menu { Button("阅读记录与笔记…") { store.readingExportEssay = false;store.openReadingDesk(.exports,window:true) };Button("当前文件导出 PDF…") { store.exportActive() };if let note { Button("当前文件导出 Word…") { note.exportWord() } } } label:{label(action,menu:menu)}.menuStyle(.borderlessButton).menuIndicator(.hidden).help(action.menuTitle)
        } else { Button { perform(action) } label:{label(action,menu:menu)}.help(action.menuTitle).accessibilityLabel(action.title).disabled(unavailable(action)) }
    }
    @ViewBuilder private func label(_ action:FileToolbarAction,menu:Bool)->some View { if menu { Label(action.menuTitle,systemImage:action.symbol) } else { Image(systemName:action.symbol).frame(width:28,height:28) } }
    private func unavailable(_ action:FileToolbarAction)->Bool {
        switch action { case .search:return !store.canSearchPDF;case .pdfPages:return (workspace?.count ?? 0) == 0;case .comment:return (workspace?.count ?? 0) == 0 || workspace?.readingLocked == true;case .save:return !store.canSave;case .annotate:return (workspace?.count ?? 0) == 0 || workspace?.readingLocked == true;case .tools:return workspace == nil || workspace?.readingLocked == true;default:return false }
    }
    private func perform(_ action:FileToolbarAction) {
        switch action {
        case .newFile:break
        case .search:store.openPDFSearch()
        case .pdfPages:store.activeWorkspace?.pageEditing053=true
        case .comment:workspace?.selectTool(.note);workspace?.showAnnotationBar = true;workspace?.status = "点击 PDF 页面放置评论"
        case .open:store.open()
        case .library:store.openReadingDesk(.search,window:true)
        case .note:store.newReadingNote()
        case .essay:store.newReadingNote()
        case .annotate:workspace?.showAnnotationBar.toggle()
        case .tools:workspace?.showTools = true
        case .save:store.saveActive()
        case .newPDF:store.newPDF()
        case .newMarkdown:store.newNote()
        case .newText:store.newNote(format:.plain)
        case .newHTML:store.newNote(format:.html)
        case .quickNote:store.newReadingNote()
        case .books:store.showReadingHistory = true
        case .jobs:store.showBackgroundJobs = true
        case .sidebar:store.toggleRightReadingPanel()
        case .excerpt,.export,.signature:break
        }
    }
}
