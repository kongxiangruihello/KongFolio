import SwiftUI

struct EditorReplaceView: View {
    @ObservedObject var session:WritingSession
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var selection = NSRange(location:0,length:0)
    @State private var scoped = false
    @State private var query = ""
    @State private var replacement = ""
    @State private var plan:EditorReplacePlan?
    @State private var checked = Set<Int>()
    @State private var page = 0
    @State private var message = ""
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("逐项预览替换").font(.headline)
            Toggle("仅替换打开窗口前选中的文字",isOn:$scoped).disabled(selection.length == 0)
            HStack { TextField("查找文字",text:$query);TextField("替换为",text:$replacement);Button("查找并预览") { search() }.disabled(query.isEmpty) }
            Text("选择范围：\(scoped ? "选中文字" : "全文")；修改查找或范围后，请重新预览。").font(.caption)
            if let plan {
                List { ForEach(Array(plan.matches.dropFirst(page*40).prefix(40))) { hit in Toggle(isOn:Binding(get:{checked.contains(hit.id)},set:{if $0 { checked.insert(hit.id) } else { checked.remove(hit.id) }})) { Text(hit.context).font(.system(.caption,design:.monospaced)) } } }
                HStack { Button("全选") { checked = Set(plan.matches.map(\.id)) };Button("取消全选") { checked = [] };Text("\(checked.count) / \(plan.matches.count) 处");Spacer();Button("上一页") { page-=1 }.disabled(page == 0);Text("\(page+1)");Button("下一页") { page+=1 }.disabled((page+1)*40>=plan.matches.count) }
            } else { Spacer() }
            Text(message).font(.caption).foregroundStyle(.orange)
            HStack { Button("取消") { dismiss() };Spacer();Button("替换勾选的匹配") { apply() }.disabled(checked.isEmpty || plan == nil) }
        }.padding(20).adaptiveSheet(width:800,height:560,minimumWidth:480)
        .onAppear { if let v = session.view { source = v.string;selection = v.selectedRange();scoped = selection.length>0;if scoped { query = (source as NSString).substring(with:selection) } } }
        .onChange(of:query) { _,_ in plan = nil;checked = [] }.onChange(of:scoped) { _,_ in plan = nil;checked = [] }
    }
    private func search() { do { guard source.utf16.count<=2_000_000 else { throw FolioError(message:"请分拆较大正文后逐项替换") };let p = try EditorReplacePlan(source:source,query:query,scope:scoped ? selection : nil);plan = p;checked = Set(p.matches.map(\.id));page = 0;message = p.matches.isEmpty ? "没有匹配" : "勾选后可一次替换、一次撤销" } catch { message = error.localizedDescription } }
    private func apply() { guard let v = session.view,v.string == source,v.isEditable,!v.hasMarkedText(),let plan,let edit = plan.edit(selected:checked,replacement:replacement) else { message = "正文已变化或正在输入，请完成输入后重新打开";return };WritingEdit.apply(edit,to:v);dismiss() }
}
