import SwiftUI

/// Editing keeps its own space; a narrow panel navigates instead of stacking
/// a short list on top of an even shorter native text view.
struct ReadingBrowserLayout<Browser:View,Editor:View>:View {
    let hasEditor:Bool
    var compact = false
    var deskSection: Binding<ReadingDeskSection>? = nil
    var onBack:()->Void
    @ViewBuilder var browser:()->Browser
    @ViewBuilder var editor:()->Editor
    var body:some View {
        GeometryReader { proxy in
            if proxy.size.width >= 820 && !compact {
                HSplitView {
                    browserArea.frame(minWidth:260,idealWidth:300,maxWidth:370,maxHeight:.infinity,alignment:.topLeading)
                    editorArea.frame(minWidth:400,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }
            } else if hasEditor {
                VStack(alignment:.leading,spacing:10) {
                    deskHeader
                    Button(action:onBack) { Label("返回记录列表",systemImage:"chevron.left") }.buttonStyle(.borderless)
                    editorArea
                }
            } else { browserArea }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var browserArea: some View {
        VStack(alignment:.leading,spacing:8) {
            deskHeader
            browser()
        }
    }

    @ViewBuilder private var deskHeader: some View {
        if let deskSection { ReadingDeskHeader(title:"阅读资料库",section:deskSection) }
    }

    @ViewBuilder private var editorArea:some View {
        if hasEditor { VStack(alignment:.leading,spacing:8) { editor() }.padding(.leading,8) }
        else {
            ContentUnavailableView("选择一条记录开始编辑",systemImage:"square.and.pencil",description:Text("在左侧查找摘录、标注、评论和笔记，或点“新增”开始记录。"))
                .frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}
