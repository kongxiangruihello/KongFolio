import SwiftUI

/// The one toolbar entry whose destinations are all in the main window's right side.
struct LeftPanelActions: View {
    @ObservedObject var store:WorkspaceStore
    @AppStorage(LayoutKeys.inspector) private var inspector = true
    @AppStorage(LayoutKeys.sidebar) private var sidebar = true
    var body:some View {
        Button("页面导航") { store.showReadingDesk=false;inspector=false;sidebar=true;store.commandWorkspace?.requestedSidebar053=false }
        ForEach([ReadingDeskSection.search,.excerpts,.notes],id:\.self) { section in
            Button(section == .search ? "阅读资料库（左侧）" : section.rawValue+"（左侧）") { inspector=false;store.commandWorkspace?.requestedSidebar053=false;store.showReadingPanel(section) }
        }
        Button("PDF 属性与标注（左侧）") { store.showReadingDesk=false;store.readingMode=false;inspector=true;store.commandWorkspace?.requestedSidebar053=false }.disabled(store.commandWorkspace == nil)
        Button("隐藏左侧辅助面板") { store.showReadingDesk=false;inspector=false;sidebar=false;store.commandWorkspace?.requestedSidebar053=false }
    }
}

struct RightPanelHeader: View {
    let title:String
    var close:()->Void
    var body:some View {
        HStack { Label(title,systemImage:"sidebar.left").font(.system(size:13,weight:.semibold));Spacer();Button(action:close) { Image(systemName:"xmark") }.buttonStyle(.borderless).help("隐藏左侧面板").accessibilityLabel("隐藏左侧面板") }
            .padding(.horizontal,12).padding(.vertical,9).background(.bar)
    }
}
struct ReadingSidePanel: View {
    @ObservedObject var store:WorkspaceStore
    var body:some View {
        VStack(spacing:0) {
            RightPanelHeader(title:"左侧 · 阅读资料") { store.showReadingDesk = false }
            Divider()
            ReadingDeskView(store:store,journal:store.journal,section:Binding(get:{store.readingDeskSection},set:{store.readingDeskSection = $0}),compact:true)
        }
    }
}
struct NarrowReadingPanelNotice: View {
    @ObservedObject var store:WorkspaceStore
    var body:some View {
        HStack { Label("窗口较窄，左侧阅读资料暂未显示",systemImage:"sidebar.left").lineLimit(1);Spacer();Button("独立窗口打开") { store.readingDeskWindowRequest = UUID() };Button { store.showReadingDesk = false } label:{Image(systemName:"xmark")}.help("隐藏左侧面板") }.font(.system(size:12)).padding(8).background(.bar)
    }
}
