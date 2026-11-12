import SwiftUI

struct LibraryWritingEditor: View {
    @Binding var text:String
    let label:String
    let identity:String
    var onFocus:(()->Void)? = nil
    var onEscape:(()->Void)? = nil
    var onParagraph:((WritingEdit.ParagraphAction, NSRange) -> Bool)? = nil
    @StateObject private var session = WritingSession()
    @State private var display = LibraryWritingPreferences.load()
    @State private var showDisplay = false
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(alignment:.top) {
                LibraryWritingToolbar(session:session)
                Button { showDisplay = true } label:{Image(systemName:"textformat.size")}.buttonStyle(.borderless).help("正文字号、行距与行宽").accessibilityLabel("正文显示设置")
            }.padding(.horizontal,10).padding(.top,6)
            StableTextEditor(text:$text,label:label,identity:identity,session:session,markdown:true,onFocus:onFocus,display:display,onEscape:onEscape).frame(minHeight:220)
            HStack { WritingCharacterCount(session:session);Spacer();Text("⌘Z 撤销") }.font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,8)
        }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:10))
        .overlay { RoundedRectangle(cornerRadius:10).stroke(.quaternary) }
        .onAppear { session.analyze(text);session.paragraphHandler = onParagraph }.onChange(of:text) { _,value in session.analyze(value) }
        .sheet(isPresented:$showDisplay) { ReadingWritingDisplaySheet(options:$display) }
    }
}
struct ReadingWritingDisplaySheet:View {
    @Binding var options:EditorDisplayOptions
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("正文显示").font(.title2.bold())
            Text("只调整阅读和编辑时的显示，不改变笔记内容或导出版式。").foregroundStyle(.secondary)
            HStack { Text("字号");Slider(value:$options.size,in:14...30,step:1);Text("\(Int(options.size))") }
            HStack { Text("行距");Slider(value:$options.lineHeight,in:1.2...2,step:0.1);Text(String(format:"%.1f",options.lineHeight)) }
            Picker("字体",selection:$options.face) { ForEach(EditorDisplayOptions.Face.allCases,id:\.self) { Text($0.rawValue) } }
            Picker("行宽",selection:$options.column) { ForEach(EditorDisplayOptions.Column.allCases,id:\.self) { Text($0.rawValue) } }
            HStack { Button("恢复默认") { options = EditorDisplayOptions() };Spacer();Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:440)
        .onChange(of:options) { _,value in LibraryWritingPreferences.save(value) }
    }
}

struct LibraryWritingToolbar: View {
    @ObservedObject var session:WritingSession
    @Environment(\.isEnabled) private var enabled
    @State private var showFind = false
    @State private var showCleanup = false
    @State private var showReplacePreview = false
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    Button { session.wrap("**","**",placeholder:"粗体") } label:{Image(systemName:"bold").frame(width:24,height:24)}.help("加粗（⌘B）")
                    Button { session.wrap("*","*",placeholder:"斜体") } label:{Image(systemName:"italic").frame(width:24,height:24)}.help("斜体（⌘I）")
                    Button { session.prefix("- ") } label:{Image(systemName:"list.bullet").frame(width:24,height:24)}.help("无序列表")
                    Button { session.prefix("> ") } label:{Image(systemName:"text.quote").frame(width:24,height:24)}.help("引用段落")
                    Menu("编辑") {
                        ForEach(1...3,id:\.self) { level in Button("\(level) 级标题") { session.prefix(String(repeating:"#",count:level)+" ") } }
                        Button("有序列表") { session.prefix("1. ") }
                        Button("插入链接") { session.wrap("[","](https://)",placeholder:"链接文字") }
                        Button("清除格式") { session.clearFormatting() }
                        Divider()
                        Button("查找替换") { session.beginFind();showFind = true }
                        Button("逐项替换…") { showReplacePreview = true }
                        Button("整理粘贴…") { showCleanup = true }
                    }.fixedSize()
                    WritingParagraphMenu(session:session)
                    Menu("大纲") { if session.analysis.headings.isEmpty { Text("设置标题后可在这里跳转") };ForEach(session.analysis.headings) { h in Button(h.title) { session.go(h.range) } } }.fixedSize()
                }.buttonStyle(.borderless).font(.system(size:14)).controlSize(.regular).padding(.vertical,4)

            }
            if showFind { WritingFindBar(session:session) { session.endFind();showFind = false } }
            if !session.message.isEmpty { Text(session.message).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of:session.findRequest) { _,_ in session.beginFind();showFind = true }
        .onChange(of:session.cleanupRequest) { _,_ in showCleanup = true }
        .sheet(isPresented:$showReplacePreview) { EditorReplaceView(session:session) }
        .sheet(isPresented:$showCleanup) { WritingCleanupView(session:session) }
    }
}
