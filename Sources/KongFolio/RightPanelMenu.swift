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

struct ReadingExcerptActions: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Button("查看摘录") { store.showReadingPanel(.excerpts) }
        Button("摘录选中文字") {
            store.showReadingPanel(.excerpts)
            store.commandWorkspace?.excerptSelection()
        }.disabled(!store.canSearchPDF)
        Button("框选图片摘录") { store.startReadingRegionCapture() }.disabled(!store.canSearchPDF)
        Menu("框选并识别文字") {
            ForEach(ReadingImageOCRMode.allCases) { mode in
                Button(mode.rawValue) { store.startReadingRegionCapture(ocr:mode) }
            }
        }.disabled(!store.canSearchPDF)
    }
}

struct RightReadingPanelLayout<Content: View>: View {
    @ObservedObject var store: WorkspaceStore
    @ViewBuilder var content: () -> Content


    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let split = store.activeWorkspace?.splitPartner != nil && LayoutMetrics.showsSplit(width:width)
            let docked = width >= (split ? 1080 : 560)
            HSplitView {
                content().frame(minWidth:240,maxWidth:.infinity,maxHeight:.infinity)
                if store.rightReadingPanelVisible && docked {
                    panel.frame(minWidth:280,idealWidth:330,maxWidth:400)
                }
            }
            .overlay(alignment:.trailing) {
                if store.rightReadingPanelVisible && !docked {
                    panel.frame(width:min(370,max(260,width-44)))
                        .shadow(color:.black.opacity(0.18),radius:8,x:-3)
                }
            }
        }
    }

    private var panel: some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                panelTab("搜索",selected:store.rightPDFSearchWorkspace != nil) { store.openPDFSearch() }
                    .disabled(!store.canSearchPDF)
                panelTab("摘录",selected:isSelected(.excerpts)) { store.showReadingPanel(.excerpts) }
                panelTab("笔记",selected:isSelected(.notes)) { store.showReadingPanel(.notes) }
                panelTab("全部资料",selected:isSelected(.search)) { store.showReadingPanel(.search) }
                Spacer(minLength:0)
                if store.showReadingDesk && store.readingDeskSection == .notes {
                    Button { store.newReadingNote() } label: { Image(systemName:"plus") }
                        .buttonStyle(.borderless).help("新建笔记").accessibilityLabel("新建笔记")
                        .disabled(store.journal.unreadable)
                }
                if store.showReadingDesk {
                    Button { store.openReadingDesk(store.readingDeskSection,window:true) } label: { Image(systemName:"arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless).help("在独立窗口打开阅读资料").accessibilityLabel("在独立窗口打开阅读资料")
                }
                Button { store.closeRightReadingPanel() } label: { Image(systemName:"xmark") }
                    .buttonStyle(.borderless).help("隐藏右侧面板").accessibilityLabel("隐藏右侧面板")
            }.font(.system(size:12)).padding(.horizontal,8).padding(.vertical,9).background(.bar)
            Divider()
            if store.showReadingDesk {
                ReadingDeskView(store:store,journal:store.journal,section:$store.readingDeskSection,compact:true)
            } else if let workspace = store.rightPDFSearchWorkspace {
                ReadingSidebar(workspace:workspace,searchOnly:true).id(workspace.id).padding(.top,10)
            }
        }.frame(maxHeight:.infinity).background(Color(nsColor:.windowBackgroundColor))
    }
    private func isSelected(_ section: ReadingDeskSection) -> Bool {
        store.showReadingDesk && (store.readingDeskSection == section ||
                                  (section == .notes && store.readingDeskSection == .essays))
    }

    private func panelTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action:action) {
            Text(title).fontWeight(selected ? .semibold : .regular).fixedSize()
                .padding(.horizontal,4).padding(.vertical,3)
                .background(selected ? Color.accentColor.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:4))
        }.buttonStyle(.borderless).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension WorkspaceStore {
    var rightReadingPanelVisible: Bool { showReadingDesk || rightPDFSearchWorkspace != nil }

    func toggleRightReadingPanel() {
        if rightReadingPanelVisible { closeRightReadingPanel() }
        else if !lastRightPanelWasSearch || !openPDFSearch() { showReadingPanel(readingDeskSection) }
    }
}
