import SwiftUI
import UniformTypeIdentifiers

struct FileEditingSheet: View {
    @ObservedObject var note:MarkdownNote
    let tool:FileEditingTool
    @Environment(\.dismiss) private var dismiss
    @State private var source:String
    @State private var selection:NSRange
    init(note:MarkdownNote,tool:FileEditingTool) { self.note = note;self.tool = tool;_source = State(initialValue:note.text);_selection = State(initialValue:note.textView?.selectedRange() ?? NSRange(location:0,length:0)) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(tool.rawValue).font(.headline);Spacer();Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            if note.readOnly { Text("当前为阅读模式。可以查看；需要修改正文时请先切换为编辑模式。").font(.caption).foregroundStyle(.orange) }
            if source.utf16.count > 2_000_000 { Text("正文较大，请先按章节拆分副本，再使用结构编辑工具。阅读、保存和普通输入仍可使用。").foregroundStyle(.orange);Spacer() }
            else {
                switch tool {
                case .paragraphs:EditorParagraphPane(note:note,source:source,selection:selection)
                case .table:EditorTablePane(note:note,source:source,selection:selection)
                case .images:EditorImagePane(note:note,source:source,selection:selection)
                case .footnotes:EditorFootnotePane(note:note,source:source,selection:selection)
                case .history:EditorHistoryPane(note:note,source:source)
                case .merge:EditorMergePane(note:note,source:source)
                case .corrections:EditorCorrectionPane(note:note,source:source,selection:selection)
                case .encoding:EditorEncodingPane(note:note)
                case .characters:EditorCharacterPane(note:note,source:source)
                }
            }
        }.padding(18).adaptiveSheet(width:880,height:620,minimumWidth:480)
    }
}
struct EditorParagraphPane: View {
    @ObservedObject var note:MarkdownNote
    let source:String;let selection:NSRange
    @Environment(\.dismiss) private var dismiss
    @State private var sections = true
    @State private var selected:Int?
    @State private var confirmDelete = false
    private var blocks:[EditorBlock] { EditorBlocks.blocks(source,sections:sections && note.format == .markdown) }
    var body:some View {
        VStack(alignment:.leading) {
            if note.format == .markdown { Toggle("按标题章节整理（包含章内图片、引用与注释）",isOn:$sections).onChange(of:sections) { _,_ in selected = nil } }
            Text("选中一段或一章后移动、复制或删除。修改可一次撤销；代码块内的 # 不作为标题。").font(.caption)
            List(selection:$selected) { ForEach(Array(blocks.enumerated()),id:\.element.id) { index,block in Text(block.title.isEmpty ? "空段落" : block.title).lineLimit(2).tag(index).help((source as NSString).substring(with:block.range)) } }
            HStack { Button("上移") { perform("up") }.disabled(selected == nil || selected == 0);Button("下移") { perform("down") }.disabled(selected == nil || selected == blocks.count-1);Button("复制整段 / 整章") { perform("copy") };Button("删除…",role:.destructive) { confirmDelete = true } }.disabled(note.readOnly || selected == nil)
        }.onAppear { selected = blocks.firstIndex { NSLocationInRange(selection.location,$0.range) } }
        .alert("删除选中的整段或整章？",isPresented:$confirmDelete) { Button("取消",role:.cancel) {};Button("删除",role:.destructive) { perform("delete") } } message:{ Text("包含其中的图片和引用；原始图片文件会保留。可用撤销恢复。") }
    }
    private func perform(_ action:String) { if let selected,let edit = EditorBlocks.edit(source,blocks:blocks,index:selected,action:action),note.commitEditorEdit(edit,expected:source) { dismiss() } }
}
struct EditorTablePane: View {
    @ObservedObject var note:MarkdownNote
    let source:String;let selection:NSRange
    @Environment(\.dismiss) private var dismiss
    @State private var table:EditorTable?
    @State private var message = ""
    @State private var row = 0
    @State private var column = 0
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("光标放在现有表格中可编辑；否则在光标处插入新表格。第一行为表头。粘贴会替换本窗口的表格草稿。").font(.caption)
            if let value = table {
                ScrollView([.horizontal,.vertical]) {
                    VStack(spacing:5) { ForEach(value.rows.indices,id:\.self) { r in HStack(spacing:5) { Text("\(r+1)").frame(width:24);ForEach(value.rows[r].indices,id:\.self) { c in TextField("",text:cell(r,c)).frame(width:130).textFieldStyle(.roundedBorder).onTapGesture { row = r;column = c } } } } }
                }
                HStack { Button("加行") { if (table?.rows.count ?? 0)<200 { table?.rows.insert(Array(repeating:"",count:value.rows[0].count),at:min(row+1,value.rows.count)) } };Button("删第 \(row+1) 行") { if value.rows.count>1 { table?.rows.remove(at:min(row,value.rows.count-1));row = 0 } };Button("加列") { if value.rows[0].count<30 { for r in value.rows.indices { table?.rows[r].insert("",at:min(column+1,value.rows[r].count)) } } };Button("删第 \(column+1) 列") { if value.rows[0].count>1 { for r in value.rows.indices { table?.rows[r].remove(at:min(column,value.rows[r].count-1)) };column = 0 } } }
                HStack { Button("粘贴 Excel / 制表符表格") { do { if let t = NSPasteboard.general.string(forType:.string) { try table?.pasteTSV(t);row = 0;column = 0 } } catch { message = error.localizedDescription } };Spacer();Button("采用表格") { if let table,note.commitEditorEdit(table.edit(format:note.format),expected:source) { dismiss() } }.disabled(note.readOnly) }
            }
            Text(message).font(.caption).foregroundStyle(.orange)
        }.onAppear { guard note.format != .plain else { message = "纯文本请使用制表符分列，或另存为 Markdown / HTML";return };do { table = try EditorTable.capture(source,selection:selection,format:note.format) } catch { message = error.localizedDescription } }
    }
    private func cell(_ r:Int,_ c:Int)->Binding<String> { Binding(get:{table?.rows[r][c] ?? ""},set:{ table?.rows[r][c] = $0;row = r;column = c }) }
}
struct EditorFootnotePane: View {
    @ObservedObject var note:MarkdownNote
    let source:String;let selection:NSRange
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var selected:String?
    @State private var message = ""
    private var notes:[EditorFootnote] { EditorFootnotes.list(source) }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Markdown 解释性脚注独立于文献出处。PDF 中汇列注释，Word 使用真正的脚注。编号按正文自动显示。").font(.caption)
            List(selection:$selected) { ForEach(Array(notes.enumerated()),id:\.element.id) { i,n in Text("[\(i+1)] "+n.body).tag(n.id) } }.frame(minHeight:140)
            HStack { Button("跳到正文引用") { if let n = notes.first(where:{$0.id == selected}),let r = n.references.first { note.writingSession.go(r);dismiss() } };Button("跳到注释定义") { if let n = notes.first(where:{$0.id == selected}) { note.writingSession.go(n.definition);dismiss() } } }.disabled(selected == nil)
            Text("新增解释性脚注（插入到打开工具前的光标或选中文字后）").font(.caption)
            StableTextEditor(text:$bodyText,label:"解释性脚注正文").frame(minHeight:110)
            HStack { Text(message).font(.caption).foregroundStyle(.orange);Spacer();Button("插入脚注") { do { if note.commitEditorEdit(try EditorFootnotes.insertion(source,selection:selection,body:bodyText),expected:source) { dismiss() } } catch { message = error.localizedDescription } }.disabled(note.readOnly || note.format != .markdown || bodyText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.onAppear { if note.format != .markdown { message = "脚注编辑请使用 Markdown；HTML 可使用链接锚点" } }
    }
}
struct EditorCorrectionPane: View {
    @ObservedObject var note:MarkdownNote
    let source:String;let selection:NSRange
    @Environment(\.dismiss) private var dismiss
    @State private var replacement = ""
    @State private var reason = ""
    @State private var kind = "阙文补字"
    @State private var change = false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("原文："+((source as NSString).substring(with:MarkdownNote.clamp(selection,to:source.utf16.count)))).textSelection(.enabled)
            Picker("校勘类型",selection:$kind) { ForEach(["阙文补字","存疑文字","异体字","讹误订正"],id:\.self) { Text($0) } }
            TextField("补字、建议文字或异体字说明",text:$replacement)
            TextField("判断理由或依据",text:$reason)
            Toggle("同时用建议文字替换选中原文",isOn:$change)
            Toggle("PDF / Word 导出包含独立校勘记",isOn:$note.includeCorrections)
            Text("校勘记录随文本保存，包含原文、建议文字和理由。只做记录时正文不变。").font(.caption).foregroundStyle(.secondary)
            ScrollView { LazyVStack(alignment:.leading) { ForEach(EditorCorrections.list(source)) { n in Text("【\(n.kind)】\(n.original) → \(n.replacement)\n\(n.reason)").padding(6) } } }.frame(minHeight:150)
            Button("保存校勘记录") {
                let r = MarkdownNote.clamp(selection,to:source.utf16.count),n = EditorCorrection(original:(source as NSString).substring(with:r),replacement:replacement,kind:kind,reason:reason)
                let result = NSMutableString(string:source);if change { result.replaceCharacters(in:r,with:replacement) };result.append("\n"+n.marker+"\n")
                if note.commitEditorEdit(TextEdit(range:NSRange(location:0,length:source.utf16.count),replacement:result as String,selection:NSRange(location:r.location,length:change ? replacement.utf16.count : r.length)),expected:source) { dismiss() }
            }.disabled(note.readOnly || reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
    }
}
struct EditorCharacterPane: View {
    @ObservedObject var note:MarkdownNote
    let source:String
    @Environment(\.dismiss) private var dismiss
    @State private var showSpaces = true
    @State private var page = 0
    private var entries:[EditorCharacter] { EditorCharacters.inspect(source,all:showSpaces) }
    var body:some View {
        VStack(alignment:.leading) {
            Toggle("显示普通空格（·）、制表符（⇥）和换行（↵）的位置",isOn:$showSpaces).onChange(of:showSpaces) { _,_ in page = 0 }
            Text("原文不插入替代符号。选择一项可定位正文；最多检查前 1000 处，以免长文件阻塞界面。").font(.caption)
            List { ForEach(Array(entries.dropFirst(page*40).prefix(40))) { entry in Button { note.writingSession.go(entry.range);dismiss() } label:{HStack { Text(entry.name);Spacer();Text(entry.unicode+" · 字符位置 \(entry.range.location+1)").foregroundStyle(.secondary) }}.buttonStyle(.plain) } }
            HStack { Text("\(entries.count) 处");Spacer();Button("上一页") { page-=1 }.disabled(page == 0);Text("\(page+1) / \(max(1,Int(ceil(Double(entries.count)/40))))");Button("下一页") { page+=1 }.disabled((page+1)*40>=entries.count) }
        }
    }
}
struct EditorEncodingPane: View {
    @ObservedObject var note:MarkdownNote
    @State private var encoding:EditorEncoding = .utf8
    @State private var selectedURL:URL?
    @State private var data:Data?
    @State private var decoded = ""
    @State private var message = ""
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("预览磁盘原件的字节。确认文字正确后另存 UTF-8 副本；当前编辑和原文件均保留。").font(.caption)
            HStack { Picker("解码方式",selection:$encoding) { ForEach(EditorEncoding.allCases) { Text($0.rawValue).tag($0) } };Button("选择其他文本原件…") { let p = NSOpenPanel();p.allowedContentTypes = [.plainText,.html,.data];if p.runModal() == .OK,let url = p.url { load(url) } } }
            ScrollView { Text(decoded.isEmpty ? "请选择原文件与编码" : decoded).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).font(.system(.body,design:.monospaced)) }
            Text(message).font(.caption).foregroundStyle(.orange)
            Button("确认并另存 UTF-8 副本…") { note.createEditingCopy(text:decoded,baseURL:selectedURL?.deletingLastPathComponent(),format:selectedURL.map{TextDocumentFormat.forURL($0)}) }.disabled(decoded.isEmpty || data == nil)
        }.onAppear { if let url = note.fileURL { load(url) } }.onChange(of:encoding) { _,_ in decode() }
    }
    private func load(_ url:URL) { do { let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size <= 8_000_000 else { throw FolioError(message:"请分拆大于 8 MB 的文本后转换") };data = try Data(contentsOf:url);selectedURL = url;decode() } catch { message = error.localizedDescription;data = nil;decoded = "" } }
    private func decode() { guard let data else { return };do { decoded = try encoding.decode(data);message = decoded.contains("�") ? "含无法识别的替代字符，请核对编码" : "预览成功；请核对古籍文字是否正确" } catch { decoded = "";message = error.localizedDescription } }
}
