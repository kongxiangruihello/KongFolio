import SwiftUI
struct ExportReviewSheet: View {
    @ObservedObject var store: WorkspaceStore
    var request: ExportReviewRequest
    @State private var issues: [ExportReviewIssue] = []
    @State private var working = true
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(request.title).font(.title2.bold());Text(request.summary).foregroundStyle(.secondary)
            if working { ProgressView("正在核对页码、图片、表格和修改草稿…") }
            else {
                Text(issues.isEmpty ? "检查通过，可选择位置导出" : "\(issues.filter{$0.severity == .blocking}.count) 项需要处理 · \(issues.filter{$0.severity == .warning}.count) 项提示").font(.headline)
                ScrollView {
                    VStack(alignment:.leading,spacing:10) { ForEach(issues) { issue in
                        HStack(alignment:.top) {
                            Image(systemName:issue.severity == .blocking ? "exclamationmark.circle.fill" : "info.circle").foregroundStyle(issue.severity == .blocking ? .red : .orange)
                            Text(issue.message).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                            Button("定位问题") { store.exportReview=nil;DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { request.locate(issue) } }
                        }.padding(8).background(.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:6))
                    } }
                }.frame(minHeight:120,maxHeight:340)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            PanelRow {
                Button("关闭") { store.exportReview=nil }.keyboardShortcut(.cancelAction)
                Button("重新检查") { Task { await inspect() } }.disabled(working)
                Button("选择位置并导出…") {
                    guard request.isCurrent() else { message="内容或导出选项已变化，请关闭后重新开始检查";return }
                    store.exportReview=nil;DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { if request.isCurrent() { request.proceed() } else { store.present(FolioError(message:"内容或导出选项已变化，请重新检查")) } }
                }.disabled(working || issues.contains{$0.severity == .blocking}).buttonStyle(.borderedProminent)
            }
        }.padding(24).adaptiveSheet(width:760,height:570,minimumWidth:360,flexibleHeight:true).task { await inspect() }
    }
    private func inspect() async {
        working=true;message=""
        let operation=request.inspect
        let job=Task.detached { try operation() }
        do { let result=try await withTaskCancellationHandler(operation:{ try await job.value },onCancel:{ job.cancel() });try Task.checkCancellation();issues=result }
        catch is CancellationError {} catch { issues=[ExportReviewIssue(severity:.blocking,message:error.localizedDescription)] }
        working=false
    }
}
