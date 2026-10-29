import SwiftUI

struct ReadingToolbar: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var workspace:Workspace
    let width:CGFloat
    var body:some View {
        VStack(spacing:8) {
            HStack(spacing:8) {
                Button { let key = LayoutKeys.sidebar; UserDefaults.standard.set(!(UserDefaults.standard.object(forKey:key) as? Bool ?? true),forKey:key) } label:{Image(systemName:"sidebar.left")}.buttonStyle(.borderless).help("显示或隐藏页面导航")
                if width > 650 { Image(systemName:"square.stack.3d.up.fill").font(.title2).foregroundStyle(Brand.accent) }
                VStack(alignment:.leading,spacing:2) { if width > 650 { Text("KongFolio").font(.headline) }; Text(workspace.displayName).lineLimit(1).truncationMode(.middle).help(workspace.displayName+(workspace.displayPath.map{"\n"+$0} ?? "")) }.frame(minWidth:20,maxWidth:200,alignment:.leading)
                NewFileIcons(store:store)
                Spacer(minLength:0)
                if width >= 1050 { actions }
                Button { workspace.open() } label:{Image(systemName:"folder")}.help("打开 PDF 文献")
                Button { workspace.showAnnotationBar.toggle() } label:{Image(systemName:"pencil.tip.crop.circle")}.disabled(workspace.count == 0).help("标注工具")
                Button { workspace.showTools = true } label:{Image(systemName:"square.grid.2x2")}.help("快捷工具：OCR、页面整理与转换")
                Menu {
                    Button("个人书架（手动维护）") { store.showReadingHistory = true }
                    Button("查找摘录、笔记与札记") { store.openReadingDesk(.search,window:true) }
                    Button("阅读组、备份与史料辅助工具") { store.showResearch = true }
                    Button("完整 PDF 工具界面") { store.readingMode = false }
                    Button(store.showReadingDesk ? "收起阅读记录侧栏" : "显示阅读记录侧栏") { store.showReadingDesk.toggle() }
                    Button("打印…") { store.printActive() }.disabled(workspace.count == 0)
                } label:{Image(systemName:"ellipsis.circle")}.menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width:24).help("更多阅读与辅助工具")
            }
            if width < 1050 { actions.frame(maxWidth:.infinity,alignment:.leading) }
        }.padding(.horizontal,12).padding(.vertical,10)
    }
    private var actions:some View {
        HStack(spacing:10) {
            Menu {
                Button("摘录选中文字") { workspace.excerptSelection() }
                Button("框选图片摘录") { workspace.tool = .region; workspace.showAnnotationBar = true }
            } label:{Label("摘录",systemImage:"text.quote")}.menuStyle(.borderlessButton).fixedSize().disabled(workspace.count == 0).help("保存所选文字，或框选扫描页、插图和表格")
            Button { store.newReadingNote() } label:{Label("笔记",systemImage:"square.and.pencil")}.help("为当前页写笔记，自动保存")
            Button { store.openReadingDesk(.essays,window:true) } label:{Label("札记",systemImage:"doc.text")}.help("继续写札记，从多本书插入摘录和出处")
            Button { store.readingExportEssay = false; store.openReadingDesk(.exports,window:true) } label:{Label("导出",systemImage:"square.and.arrow.up")}.help("导出所选记录、整本书笔记或札记")
        }
    }
}
