import SwiftUI

struct PrintedPagesEditor: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var research: ResearchStore
    @ObservedObject var controller: ResearchController
    @State private var rows: [PrintedPageRow] = []
    @State private var jump = ""
    private var path: String { workspace.displayPath ?? "" }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("印刷页码对应").font(.headline)
            Text("PDF 页码从 1 开始。添加分段，选择样式，再检查每段预览。").font(.caption)
            HStack { Text("PDF 起页").frame(width:72); Text("PDF 末页").frame(width:72); Text("起始号码").frame(width:78); Text("样式").frame(width:130); Text("卷册前缀").frame(width:100); Text("预览"); Spacer() }.font(.caption)
            ForEach($rows) { $row in
                HStack {
                    TextField("起页",value:$row.start,format:.number).frame(width:72)
                    TextField("末页",value:$row.end,format:.number).frame(width:72)
                    TextField("号码",value:$row.first,format:.number).frame(width:78).disabled(row.style == .none)
                    Picker("样式",selection:$row.style) { ForEach(PrintedPageSegment.Style.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width:130)
                    TextField("如 卷一-",text:$row.prefix).frame(width:100)
                    Text(row.preview).font(.caption).lineLimit(1)
                    Spacer(); Button { rows.removeAll { $0.id == row.id } } label:{ Image(systemName:"minus.circle") }.help("删除这一段")
                }
            }
            HStack {
                Button("添加一段") { let start = (rows.map(\.end).max() ?? 0)+1; rows.append(PrintedPageRow(PrintedPageSegment(start:start-1,end:max(start-1,workspace.count-1)))) }
                Button("保存页码对应") { controller.savePageRows(rows,workspace:workspace,research:research) }.disabled(path.isEmpty || controller.busy)
                TextField("印刷页码，如 iv、卷一-12",text:$jump)
                Button("跳转") { if let page = research.page(path:path,label:jump,count:workspace.count) { workspace.selectPage(page) } else { controller.message = "未找到页码，或原文件变化后尚未核对关联" } }
            }
        }.onAppear(perform:load).onChange(of:path) { _,_ in load() }
    }
    private func load() { rows = (research.state.labels[path] ?? [PrintedPageSegment(start:0,end:max(0,workspace.count-1))]).map(PrintedPageRow.init) }
}
