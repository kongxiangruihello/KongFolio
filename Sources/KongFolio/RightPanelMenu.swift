import SwiftUI

/// The one toolbar entry whose destinations are all in the main window's right side.
struct RightPanelMenu: View {
    @ObservedObject var store:WorkspaceStore
    @AppStorage(LayoutKeys.inspector) private var inspector = true
    var body:some View {
        Menu {
            Section("在主界面右侧显示") {
                ForEach([ReadingDeskSection.search,.excerpts,.notes,.essays],id:\.self) { section in
                    Button { store.showReadingPanel(section) } label: {
                        Label(section == .search ? "阅读资料库（全部资料）" : section.rawValue,systemImage:store.showReadingDesk && store.readingDeskSection == section ? "checkmark" : "sidebar.right")
                    }
                }
                Button { store.showReadingDesk = false;store.readingMode = false;inspector = true } label: {
                    Label("PDF 属性与标注",systemImage:!store.readingMode && !store.showReadingDesk && inspector && store.activeWorkspace != nil ? "checkmark" : "slider.horizontal.3")
                }.disabled(store.activeWorkspace == nil)
                Divider()
                Button("隐藏右侧面板") { store.showReadingDesk = false;inspector = false }
            }
            Section("需要更大空间") {
                Button("在独立窗口管理阅读资料…") { store.openReadingDesk(.search,window:true) }
            }
        } label: { Image(systemName:"sidebar.right").frame(width:28,height:28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("右侧面板：显示阅读资料或 PDF 属性，当前内容带有勾号")
        .accessibilityLabel("右侧面板")
    }
}

struct RightPanelHeader: View {
    let title:String
    var close:()->Void
    var body:some View {
        HStack { Label(title,systemImage:"sidebar.right").font(.system(size:13,weight:.semibold));Spacer();Button(action:close) { Image(systemName:"xmark") }.buttonStyle(.borderless).help("隐藏右侧面板").accessibilityLabel("隐藏右侧面板") }
            .padding(.horizontal,12).padding(.vertical,9).background(.bar)
    }
}
struct ReadingSidePanel: View {
    @ObservedObject var store:WorkspaceStore
    var body:some View {
        VStack(spacing:0) {
            RightPanelHeader(title:"右侧 · 阅读资料") { store.showReadingDesk = false }
            Divider()
            ReadingDeskView(store:store,journal:store.journal,section:Binding(get:{store.readingDeskSection},set:{store.readingDeskSection = $0}),compact:true)
        }
    }
}
struct NarrowReadingPanelNotice: View {
    @ObservedObject var store:WorkspaceStore
    var body:some View {
        HStack { Label("窗口较窄，右侧阅读资料暂未显示",systemImage:"sidebar.right").lineLimit(1);Spacer();Button("独立窗口打开") { store.readingDeskWindowRequest = UUID() };Button { store.showReadingDesk = false } label:{Image(systemName:"xmark")}.help("隐藏右侧面板") }.font(.system(size:12)).padding(8).background(.bar)
    }
}
