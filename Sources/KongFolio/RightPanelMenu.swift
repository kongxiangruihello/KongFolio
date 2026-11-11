import SwiftUI

struct LeftPanelActions: View {
    @ObservedObject var store: WorkspaceStore
    @AppStorage(LayoutKeys.inspector) private var inspector = true
    @AppStorage(LayoutKeys.sidebar) private var sidebar = true

    var body: some View {
        Button("页面导航") {
            inspector = false
            sidebar = true
            store.activeWorkspace?.pageEditing053 = false
        }
        Button("PDF 属性与标注") {
            store.readingMode = false
            inspector = true
            store.activeWorkspace?.pageEditing053 = false
        }.disabled(store.activeWorkspace == nil)
        Button("隐藏左侧导航") {
            inspector = false
            sidebar = false
            store.activeWorkspace?.pageEditing053 = false
        }
    }
}

struct RightPanelActions: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Button("搜索当前 PDF 正文（⌃F）") { store.openPDFSearch() }.disabled(!store.canSearchPDF)
        Button("摘录") { store.showReadingPanel(.excerpts) }
        Button("笔记") { store.showReadingPanel(.notes) }
        Button("全部阅读资料") { store.showReadingPanel(.search) }
    }
}

struct ReadingExcerptActions: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Button("查看摘录") { store.showReadingPanel(.excerpts) }
        Button("摘录选中文字") {
            store.showReadingPanel(.excerpts)
            store.commandWorkspace?.excerptSelection()
        }.disabled(!store.canSearchPDF)
        Button("框选图片摘录") {
            store.showReadingPanel(.excerpts)
            store.commandWorkspace?.tool = .region
            store.commandWorkspace?.showAnnotationBar = true
        }.disabled(!store.canSearchPDF)
    }
}

struct RightReadingPanelLayout<Content: View>: View {
    @ObservedObject var store: WorkspaceStore
    @ViewBuilder var content: () -> Content

    private var visible: Bool { store.showReadingDesk || store.rightPDFSearchWorkspace != nil }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let split = store.activeWorkspace?.splitPartner != nil && LayoutMetrics.showsSplit(width:width)
            let docked = width >= (split ? 1080 : 560)
            HSplitView {
                content().frame(minWidth:240,maxWidth:.infinity,maxHeight:.infinity)
                if visible && docked {
                    panel.frame(minWidth:280,idealWidth:330,maxWidth:400)
                }
            }
            .overlay(alignment:.trailing) {
                if visible && !docked {
                    panel.frame(width:min(370,max(260,width-44)))
                        .shadow(color:.black.opacity(0.18),radius:8,x:-3)
                }
            }
        }
    }

    private var panel: some View {
        VStack(spacing:0) {
            HStack {
                Menu {
                    RightPanelActions(store:store)
                } label: {
                    Label(store.showReadingDesk ? store.readingDeskSection.rawValue : "PDF 正文搜索",systemImage:"sidebar.right")
                        .font(.system(size:13,weight:.semibold))
                }.menuStyle(.borderlessButton).fixedSize().help("切换右侧面板内容")
                Spacer()
                if store.showReadingDesk && store.readingDeskSection == .notes {
                    Button { store.newReadingNote() } label: { Image(systemName:"plus") }
                        .buttonStyle(.borderless).help("新建笔记").accessibilityLabel("新建笔记")
                        .disabled(store.journal.unreadable)
                }
                Button { store.closeRightReadingPanel() } label: { Image(systemName:"xmark") }
                    .buttonStyle(.borderless).help("隐藏右侧面板").accessibilityLabel("隐藏右侧面板")
            }.padding(.horizontal,12).padding(.vertical,9).background(.bar)
            Divider()
            if store.showReadingDesk {
                ReadingDeskView(store:store,journal:store.journal,section:$store.readingDeskSection,compact:true)
            } else if let workspace = store.rightPDFSearchWorkspace {
                ReadingSidebar(workspace:workspace,searchOnly:true).id(workspace.id).padding(.top,10)
            }
        }.frame(maxHeight:.infinity).background(Color(nsColor:.windowBackgroundColor))
    }
}

extension WorkspaceStore {
    func toggleRightReadingPanel() {
        if showReadingDesk || rightPDFSearchWorkspace != nil { closeRightReadingPanel() }
        else { showReadingPanel(readingDeskSection) }
    }
}
