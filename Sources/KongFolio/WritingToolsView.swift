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
    var markdownFile: MarkdownNote? = nil
    var formatting = true
    var showsControls = true
    var documentControls: AnyView? = nil
    @State private var showFind = false
    @State private var showCleanup = false
    @State private var showReplacePreview = false
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            if let documentControls, let markdownFile {
                HStack(spacing:8) {
                    documentControls.fixedSize(horizontal:true,vertical:false)
                    if showsControls {
                        Divider().frame(height:18)
                        ViewThatFits(in:.horizontal) {
                            ForEach((0...MarkdownTool.allCases.count).reversed(),id:\.self) { count in
                                markdownControls(markdownFile,visibleCount:count)
                            }
                        }
                    }
                }.buttonStyle(.borderless).font(.system(size:14)).controlSize(.regular)
            } else if showsControls {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:9) {
                        if formatting {
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
                        }
                        Button("查找替换",action:toggleFind)
                        if prominent {
                            Menu("更多编辑") {
                                if formatting { Button("清除格式") { session.clearFormatting() } }
                                Button("逐项替换…") { showReplacePreview = true }
                                Button("整理粘贴…") { showCleanup = true }
                            }
                        } else { Button("逐项替换…") { showReplacePreview = true };Button("整理粘贴…") { showCleanup = true } }
                        WritingParagraphMenu(session:session)
                        if formatting { Menu("文章大纲") { if session.analysis.headings.isEmpty { Text("使用标题后在这里跳转") };ForEach(session.analysis.headings) { h in Button(String(repeating:"　",count:max(0,h.level-1))+h.title) { session.go(h.range) } } } }
                    }.buttonStyle(.borderless).font(.system(size:prominent ? 15 : 12)).controlSize(prominent ? .regular : .small).padding(.vertical,prominent ? 5 : 0)
                }
            }
            if showFind { WritingFindBar(session:session) { session.endFind();showFind = false } }
            if !session.message.isEmpty { Text(session.message).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of:session.findRequest) { _,_ in session.beginFind();showFind = true }
        .onChange(of:session.cleanupRequest) { _,_ in showCleanup = true }
        .sheet(isPresented:$showReplacePreview) { EditorReplaceView(session:session) }
        .sheet(isPresented:$showCleanup) { WritingCleanupView(session:session) }
    }

    private func toggleFind() {
        if showFind { session.endFind() } else { session.beginFind() }
        showFind.toggle()
    }

    // Keep frequently used commands visible first. Every remaining command stays in the menu.
    private enum MarkdownTool: CaseIterable, Hashable {
        case find, headings, list, insert, bold, italic, quote, outline, link, image, table, taskList, code
    }

    private func markdownControls(_ note:MarkdownNote,visibleCount:Int) -> some View {
        let visible = MarkdownTool.allCases.prefix(visibleCount)
        return HStack(spacing:8) {
            ForEach(visible,id:\.self) { command in
                markdownTool(command,note:note)
            }
            Menu {
                ForEach(MarkdownTool.allCases.dropFirst(visibleCount),id:\.self) { command in
                    markdownMenuItem(command,note:note)
                }
                if visibleCount < MarkdownTool.allCases.count { Divider() }
                editingCommands
            } label: { Image(systemName:"ellipsis.circle") }
                .help("更多编辑").accessibilityLabel("更多编辑")
        }.fixedSize(horizontal:true,vertical:false)
    }

    @ViewBuilder private func markdownTool(_ command:MarkdownTool,note:MarkdownNote) -> some View {
        switch command {
        case .find: tool("查找替换（⌘F）","magnifyingglass",action:toggleFind)
        case .headings: headingMenu
        case .list: listMenu
        case .insert: insertionMenu(note)
        case .bold: tool("粗体","bold") { session.wrap("**","**",placeholder:"粗体") }
        case .italic: tool("斜体","italic") { session.wrap("*","*",placeholder:"斜体") }
        case .quote: tool("引用","text.quote") { session.prefix("> ") }
        case .outline: outlineMenu
        case .link: tool("链接","link") { insertLink() }
        case .image: tool("图片","photo") { note.chooseImage() }
        case .table: tool("表格","tablecells") { note.insertTable() }
        case .taskList: tool("任务列表","checklist") { session.prefix("- [ ] ") }
        case .code: tool("行内代码","chevron.left.forwardslash.chevron.right") { insertCode() }
        }
    }

    @ViewBuilder private func markdownMenuItem(_ command:MarkdownTool,note:MarkdownNote) -> some View {
        switch command {
        case .find: Button("查找替换",action:toggleFind)
        case .headings: headingMenu
        case .list: Menu("列表") { listCommands }
        case .insert: Menu("插入") { insertionCommands(note) }
        case .bold: Button("粗体") { session.wrap("**","**",placeholder:"粗体") }
        case .italic: Button("斜体") { session.wrap("*","*",placeholder:"斜体") }
        case .quote: Button("引用") { session.prefix("> ") }
        case .outline: Menu("文章大纲") { outlineCommands }
        case .link: Button("链接",action:insertLink)
        case .image: Button("图片…") { note.chooseImage() }
        case .table: Button("表格") { note.insertTable() }
        case .taskList: Button("任务列表") { session.prefix("- [ ] ") }
        case .code: Button("行内代码",action:insertCode)
        }
    }

    private func insertLink() { session.wrap("[","](https://)",placeholder:"链接文字") }
    private func insertCode() { session.wrap("`","`",placeholder:"代码") }

    private func insertionMenu(_ note:MarkdownNote) -> some View {
        Menu { insertionCommands(note) } label: { Image(systemName:"plus") }
            .help("插入").accessibilityLabel("插入")
    }

    private var headingMenu: some View {
        Menu {
            ForEach(1...6,id:\.self) { level in
                Button("标题 \(level)") { session.prefix(String(repeating:"#",count:level)+" ") }
            }
        } label: { Text("标题") }.help("设置 Markdown 标题")
    }

    private var listMenu: some View {
        Menu { listCommands } label: { Image(systemName:"list.bullet") }
            .help("列表").accessibilityLabel("列表")
    }

    @ViewBuilder private var listCommands: some View {
        Button("无序列表") { session.prefix("- ") }
        Button("有序列表") { session.prefix("1. ") }
        Button("任务列表") { session.prefix("- [ ] ") }
    }

    @ViewBuilder private func insertionCommands(_ note:MarkdownNote) -> some View {
        Button("链接",action:insertLink)
        Button("图片…") { note.chooseImage() }
        Button("表格") { note.insertTable() }
        Button("行内代码",action:insertCode)
        Button("代码块") { session.wrap("```\n","\n```",placeholder:"代码") }
        Button("分隔线") { note.insertSource("\n---\n") }
    }

    private var outlineMenu: some View {
        Menu { outlineCommands } label: { Image(systemName:"list.bullet.indent") }
            .help("文章大纲").accessibilityLabel("文章大纲")
    }

    @ViewBuilder private var outlineCommands: some View {
        if session.analysis.headings.isEmpty { Text("添加标题后可跳转") }
        ForEach(session.analysis.headings) { heading in
            Button(String(repeating:"　",count:max(0,heading.level-1))+heading.title) { session.go(heading.range) }
        }
    }

    @ViewBuilder private var editingCommands: some View {
        WritingParagraphMenu(session:session)
        Button("清除格式") { session.clearFormatting() }
        Button("逐项替换…") { showReplacePreview = true }
        Button("整理粘贴…") { showCleanup = true }
    }

    private func tool(_ name:String,_ symbol:String,action:@escaping () -> Void) -> some View {
        Button(action:action) { Image(systemName:symbol) }.help(name).accessibilityLabel(name)
    }
}
struct WritingCleanupView: View {
    @ObservedObject var session:WritingSession
    @Environment(\.dismiss) private var dismiss
    private enum PasteMode:String,CaseIterable {
        case original = "原样", joined = "合并段内断行", quote = "Markdown 引用"
    }
    @State private var mode = PasteMode.original
    @State private var raw = ""
    @State private var options = WritingCleanup()
    @State private var target = NSRange(location:0,length:0)
    @State private var original = ""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("整理粘贴文字").font(.headline)
            Text("先核对整理结果；诗文、古籍可保留原来的换行。原始文献保持原样。").font(.caption)
            Picker("粘贴方式",selection:$mode) { ForEach(PasteMode.allCases,id:\.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
            if mode == .joined {
                HStack { Toggle("合并英文行末断字",isOn:$options.dehyphenate);Toggle("清理多余空格",isOn:$options.compactSpaces) }
            }
            HSplitView { VStack { Text("原始文字");StableTextEditor(text:$raw,label:"整理前文字").frame(minHeight:220) };VStack { Text("整理结果");ScrollView { Text(prepared).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:220) } }
            HStack { Button("取消") { dismiss() };Spacer();Button("采用整理结果") {
                guard let view = session.view,view.string == original,!view.hasMarkedText() else { session.message = "正文已变化，请重新打开整理窗口";dismiss();return }
                let value = prepared;WritingEdit.apply(TextEdit(range:target,replacement:value,selection:NSRange(location:target.location+value.utf16.count,length:0)),to:view);dismiss()
            }.disabled(raw.isEmpty) }
        }.padding(20).adaptiveSheet(width:800,height:470,minimumWidth:520)
        .onAppear { guard let view = session.view else { return };original = view.string;target = view.selectedRange();let fromClipboard = session.cleanupFromClipboard;session.cleanupFromClipboard = false;raw = target.length>0 && !fromClipboard ? (view.string as NSString).substring(with:target) : (NSPasteboard.general.string(forType:.string) ?? "") }
    }
    private var prepared: String {
        switch mode {
        case .original: return raw
        case .joined:
            var cleanup = options
            cleanup.joinLines = true
            return cleanup.apply(raw)
        case .quote:
            let normalized = raw.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
            return normalized.components(separatedBy:"\n").map { $0.isEmpty ? ">" : "> "+$0 }.joined(separator:"\n")
        }
    }

}

struct WritingParagraphMenu: View {
    let session: WritingSession
    var body: some View {
        Menu("段落") {
            ForEach(WritingEdit.ParagraphAction.allCases,id:\.self) { action in
                Button(action.rawValue+"  "+action.shortcut) { session.paragraph(action) }
            }
        }.fixedSize()
    }
}

struct WritingFindBar: View {
    @ObservedObject var session: WritingSession
    let close: () -> Void
    @State private var query = ""
    @State private var replacement = ""
    @State private var confirm = false
    @State private var preview = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                TextField("查找文字",text:$query).focused($focused).onSubmit { session.find(query) }
                Button { session.find(query,backward:true) } label: { Image(systemName:"chevron.up") }.help("上一处").accessibilityLabel("上一处")
                Button { session.find(query) } label: { Image(systemName:"chevron.down") }.help("下一处").accessibilityLabel("下一处")
                Button(action:close) { Image(systemName:"xmark") }.help("关闭查找并返回编辑").accessibilityLabel("关闭查找")
            }
            HStack {
                TextField("替换为",text:$replacement)
                Menu("替换") {
                    Button("替换当前匹配") { session.replace(query,with:replacement,all:false) }
                    Button("逐项预览…") { preview = true }
                    Button("替换全部…") { confirm = true }
                }.fixedSize().disabled(query.isEmpty)
            }
            Toggle("仅在打开查找前选中的文字内搜索",isOn:$session.searchSelectionOnly)
                .disabled(!session.canSearchSelection)
        }.font(.caption)
        .onAppear { query = session.lastQuery;focused = true }
        .onChange(of:session.findRequest) { _,_ in focused = true }
        .onExitCommand(perform:close)
        .sheet(isPresented:$preview) {
            EditorReplaceView(session:session,initialQuery:query,initialReplacement:replacement,
                              useFindSelection:session.searchSelectionOnly,fromFind:true)
        }
        .alert("替换全部匹配文字？",isPresented:$confirm) {
            Button("取消",role:.cancel) {}
            Button("替换全部") { session.replace(query,with:replacement,all:true) }
        } message: {
            Text("匹配 \(session.replacePlan(query)?.matches.count ?? 0) 处。可以一次撤销。")
        }
    }
}
