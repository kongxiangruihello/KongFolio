import SwiftUI

struct WritingCharacterCount: View {
    @ObservedObject var session:WritingSession
    var body:some View { Text("\(session.analysis.characters) 字") }
}
struct ReadingWritingEditor: View {
    @Binding var text:String
    let label:String
    let identity:String
    var onFocus:(()->Void)? = nil
    @StateObject private var session = WritingSession()
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            WritingToolbar(session:session)
            StableTextEditor(text:$text,label:label,identity:identity,session:session,markdown:true,onFocus:onFocus).frame(minHeight:120)
        }.onAppear { session.analyze(text) }.onChange(of:text) { _,value in session.analyze(value) }
    }
}
struct WritingToolbar: View {
    @ObservedObject var session:WritingSession
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @State private var showFind = false
    @State private var showCleanup = false
    @State private var showReplacePreview = false
    @State private var query = ""
    @State private var replacement = ""
    @State private var confirmReplace = false
    @FocusState private var queryFocused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:9) {
                    Button { session.wrap("**","**",placeholder:"粗体") } label:{Image(systemName:"bold")}.help("加粗选中文字（⌘B）")
                    Button { session.wrap("*","*",placeholder:"斜体") } label:{Image(systemName:"italic")}.help("斜体（⌘I）")
                    Menu { ForEach(1...3,id:\.self) { level in Button("\(level) 级标题") { session.prefix(String(repeating:"#",count:level)+" ") } } } label:{Image(systemName:"textformat.size")}.help("设置标题")
                    Button { session.prefix("> ") } label:{Image(systemName:"text.quote")}.help("引用段落")
                    Button { session.wrap("[","](https://)",placeholder:"链接文字") } label:{Image(systemName:"link")}.help("插入链接")
                    if prominent {
                        Button { session.prefix("- ") } label:{Image(systemName:"list.bullet")}.help("无序列表")
                        Button { session.prefix("1. ") } label:{Image(systemName:"list.number")}.help("有序列表")
                    }
                    if !prominent { Button("清除格式") { session.clearFormatting() } }
                    Button("查找替换") { showFind.toggle() }
                    if prominent {
                        Menu("更多编辑") {
                            Button("清除格式") { session.clearFormatting() }
                            Button("逐项替换…") { showReplacePreview = true }
                            Button("整理粘贴…") { showCleanup = true }
                        }
                    } else { Button("逐项替换…") { showReplacePreview = true };Button("整理粘贴…") { showCleanup = true } }
                    Menu("文章大纲") { if session.analysis.headings.isEmpty { Text("使用标题后在这里跳转") };ForEach(session.analysis.headings) { h in Button(String(repeating:"　",count:max(0,h.level-1))+h.title) { session.go(h.range) } } }
                }.buttonStyle(.borderless).font(.system(size:prominent ? 15 : 12)).controlSize(prominent ? .regular : .small).padding(.vertical,prominent ? 5 : 0)
            }
            if showFind {
                VStack(spacing:4) {
                    HStack { TextField("查找文字",text:$query).focused($queryFocused).onSubmit { session.find(query) };Button("上一处") { session.find(query,backward:true) };Button("下一处") { session.find(query) } }
                    HStack { TextField("替换为",text:$replacement);Button("替换") { session.replace(query,with:replacement,all:false) };Button("全部替换…") { confirmReplace = true }.disabled(query.isEmpty) }
                }.font(.caption)
            }
            if !session.message.isEmpty { Text(session.message).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of:session.findRequest) { _,_ in showFind = true;queryFocused = true }
        .onChange(of:session.cleanupRequest) { _,_ in showCleanup = true }
        .sheet(isPresented:$showReplacePreview) { EditorReplaceView(session:session) }
        .sheet(isPresented:$showCleanup) { WritingCleanupView(session:session) }
        .alert("替换全部匹配文字？",isPresented:$confirmReplace) {
            Button("取消",role:.cancel) {};Button("替换全部") { session.replace(query,with:replacement,all:true) }
        } message:{Text("匹配 \(matches) 处。执行后可一次撤销；原文引用不参与其他编辑框的替换。")}
    }
    private var matches:Int { guard !query.isEmpty,let text = session.view?.string else { return 0 };return (try? NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:query),options:.caseInsensitive).numberOfMatches(in:text,range:NSRange(location:0,length:text.utf16.count))) ?? 0 }
}
struct WritingCleanupView: View {
    @ObservedObject var session:WritingSession
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""
    @State private var options = WritingCleanup()
    @State private var target = NSRange(location:0,length:0)
    @State private var original = ""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("整理粘贴文字").font(.headline)
            Text("先核对整理结果；诗文、古籍可保留原来的换行。原始文献保持原样。").font(.caption)
            HStack { Toggle("合并段内换行",isOn:$options.joinLines);Toggle("合并英文行末断字",isOn:$options.dehyphenate);Toggle("清理多余空格",isOn:$options.compactSpaces) }
            HSplitView { VStack { Text("原始文字");StableTextEditor(text:$raw,label:"整理前文字").frame(minHeight:220) };VStack { Text("整理结果");ScrollView { Text(options.apply(raw)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:220) } }
            HStack { Button("取消") { dismiss() };Spacer();Button("采用整理结果") {
                guard let view = session.view,view.string == original,!view.hasMarkedText() else { session.message = "正文已变化，请重新打开整理窗口";dismiss();return }
                let value = options.apply(raw);WritingEdit.apply(TextEdit(range:target,replacement:value,selection:NSRange(location:target.location+value.utf16.count,length:0)),to:view);dismiss()
            }.disabled(raw.isEmpty) }
        }.padding(20).adaptiveSheet(width:800,height:470,minimumWidth:520)
        .onAppear { guard let view = session.view else { return };original = view.string;target = view.selectedRange();raw = target.length>0 ? (view.string as NSString).substring(with:target) : (NSPasteboard.general.string(forType:.string) ?? "") }
    }
}
