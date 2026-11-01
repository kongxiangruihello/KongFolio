import SwiftUI

struct FunctionToolbar: View {
    @ObservedObject var store:WorkspaceStore
    @State private var showLayout = false
    @State private var measuredWidth:CGFloat = 1000
    private var workspace:Workspace? { store.commandWorkspace }
    private var note:MarkdownNote? { store.activeNote }
    private let count = 18
    var body:some View {
        GeometryReader { proxy in
            HStack(alignment:.center,spacing:10) {
                VStack(alignment:.leading,spacing:3) {
                    Text("KongFolio").font(.caption.weight(.semibold))
                    Text(store.activeTab?.switcherTitle ?? "新标签页").font(.caption).lineLimit(1).truncationMode(.middle).help(store.activeTab?.switcherTitle ?? "新标签页")
                }.frame(width:145,alignment:.leading)
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(minimum:32),spacing:4),count:FunctionToolbarLayout.columns(width:proxy.size.width,count:count)),spacing:4) {
                    icon("显示或隐藏页面导航","sidebar.left") { let key = LayoutKeys.sidebar;UserDefaults.standard.set(!(UserDefaults.standard.object(forKey:key) as? Bool ?? true),forKey:key) }
                    icon("新建 PDF","doc.badge.plus") { store.newPDF() }
                    icon("新建 Markdown","square.and.pencil") { store.newNote() }
                    icon("新建文本文件","doc.text") { store.newNote(format:.plain) }
                    icon("新建 HTML","chevron.left.forwardslash.chevron.right") { store.newNote(format:.html) }
                    icon("打开文献或文本文件","folder") { store.open() }
                    icon("资料库：管理摘录、笔记与札记","books.vertical.fill") { store.openReadingDesk(.search,window:true) }
                    Menu { Button("摘录选中文字") { workspace?.excerptSelection() };Button("框选图片摘录") { workspace?.tool = .region;workspace?.showAnnotationBar = true } } label:{symbol("text.quote")}.menuStyle(.borderlessButton).menuIndicator(.hidden).help("摘录文字或框选图片").disabled((workspace?.count ?? 0) == 0)
                    icon("速记（⌥⌘N）","pencil.and.scribble") { store.showQuickReadingNote = true }.keyboardShortcut("n",modifiers:[.command,.option]).popover(isPresented:$store.showQuickReadingNote) { QuickReadingNote(store:store) }
                    icon("为当前页写笔记","note.text.badge.plus") { store.newReadingNote() }
                    icon("札记：整理个人论述与文献引用","doc.richtext") { store.openReadingDesk(.essays,window:true) }
                    icon("保存当前文档（⌘S）","square.and.arrow.down") { store.saveActive() }.disabled(!store.canSave)
                    icon("标注工具","pencil.tip.crop.circle") { workspace?.showAnnotationBar.toggle() }.disabled((workspace?.count ?? 0) == 0)
                    icon("快捷工具：OCR、页面整理与转换","square.grid.2x2") { workspace?.showTools = true }.disabled(workspace == nil)
                    Menu {
                        Button("阅读记录与札记…") { store.readingExportEssay = false;store.openReadingDesk(.exports,window:true) }
                        Button("当前文件导出 PDF…") { store.exportActive() }
                        if let note { Button("当前文件导出 Word…") { note.exportWord() } }
                    } label:{symbol("square.and.arrow.up")}.menuStyle(.borderlessButton).menuIndicator(.hidden).help("导出阅读记录、札记或当前文件")
                    icon("个人书架、阅读记录与快捷方式","books.vertical") { store.showReadingHistory = true }
                    icon("文件读取状态与后台任务","checklist") { store.showBackgroundJobs = true }
                    Menu {
                        Button("启动恢复与阅读内存…") { store.showReadingSettings = true }
                        Button("跨文件全文搜索…") { store.showFolderSearch = true }
                        if let note {
                            Button("另存文件…") { note.save(asNew:true) };Button("文本历史版本") { note.showVersionHistory = true }
                            Button("插入图片…") { note.chooseImage() }.disabled(note.format == .plain)
                            Button("插入表格") { note.insertTable() }.disabled(note.format == .plain)
                            Button("排版与预览设置…") { showLayout = true }
                        }
                        Button("打印…") { store.printActive() }
                        Button("阅读资料侧栏") { store.showReadingDesk.toggle() }
                        Button(store.readingMode ? "完整 PDF 工具界面" : "专注阅读界面") { store.readingMode.toggle() }
                        Button("阅读与史料辅助工具") { store.showResearch = true }
                        Divider();Button("检查更新…") { AppUpdateWindow.shared.show() }
                    } label:{symbol("ellipsis.circle")}.menuStyle(.borderlessButton).menuIndicator(.hidden).help("更多功能与阅读设置")
                }.buttonStyle(.borderless)
            }.padding(.horizontal,12).padding(.vertical,6)
            .onAppear { measuredWidth = proxy.size.width }.onChange(of:proxy.size.width) { _,value in measuredWidth = value }
        }.frame(height:CGFloat(Int(ceil(18.0/Double(FunctionToolbarLayout.columns(width:measuredWidth,count:count))))*36+12))
        .sheet(isPresented:$showLayout) { if let note { TextLayoutSheet(note:note) } }
    }
    private func symbol(_ name:String) -> some View { Image(systemName:name).font(.system(size:16)).frame(maxWidth:.infinity,minHeight:28).contentShape(Rectangle()) }
    private func icon(_ title:String,_ name:String,action:@escaping ()->Void) -> some View { Button(action:action) { symbol(name) }.accessibilityLabel(title).help(title) }
}
