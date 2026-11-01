import SwiftUI

struct ReadingRuntimeSettings: View {
    @ObservedObject var store:WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var policy = ReadingLaunchPolicy.all
    @State private var idle = 60
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("启动恢复与阅读内存").font(.headline)
            Picker("下次启动",selection:$policy) { ForEach(ReadingLaunchPolicy.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            Text("未恢复的标签页可稍后逐本打开；异常退出时始终先检查恢复副本，避免覆盖未保存内容。").font(.caption).foregroundStyle(.secondary)
            if !store.startupEntries.isEmpty { Button("选择恢复暂存的 \(store.startupEntries.count) 个标签页…") { dismiss();DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { store.showStartupReview = true } } }
            Picker("后台文献闲置后释放内存",selection:$idle) { Text("30 秒").tag(30);Text("1 分钟").tag(60);Text("3 分钟").tag(180);Text("仅按内存预算释放").tag(0) }
            Stepper("最多保留 \(store.maxLoadedTabs) 个已载入文献",value:$store.maxLoadedTabs,in:1...24)
            Stepper("内存预算 \(store.memoryBudgetMB) MB",value:$store.memoryBudgetMB,in:128...4096,step:128)
            Text("当前阅读、并排阅读、尚未保存和正在处理的文献保留。其他标签页释放缓存后，页码、缩放与撤销记录按已有缓存流程恢复。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("现在整理后台缓存") { store.releaseIdleTabs(now:Date().addingTimeInterval(3600)) };Spacer();Button("完成") { dismiss() } }
        }.padding(22).adaptiveSheet(width:610,height:400)
        .onAppear { policy = ReadingLaunchPolicy(rawValue:store.readingDefaults.string(forKey:ReadingLaunchPolicy.key) ?? "") ?? .all;idle = store.readingDefaults.object(forKey:"KongFolio.idleTabSeconds") as? Int ?? 60 }
        .onChange(of:policy) { _,value in store.readingDefaults.set(value.rawValue,forKey:ReadingLaunchPolicy.key) }
        .onChange(of:idle) { _,value in store.readingDefaults.set(value,forKey:"KongFolio.idleTabSeconds") }
    }
}
struct ReadingOpenQueue: View {
    @ObservedObject var store:WorkspaceStore
    @State private var page = 0
    private var documents:[Workspace] { store.tabs.compactMap(\.workspace).filter{$0.sourceURL != nil || $0.projectURL != nil} }
    private var pagination:ReadingPagination { ReadingPagination(total:documents.count,page:page,size:10) }
    var body:some View {
        DisclosureGroup("文献读取状态 · \(documents.count) 份") {
            VStack(spacing:8) {
                Text("未切换的文献按需读取；一份文件等待下载或失败时，可继续阅读其他文献。").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(documents.dropFirst(pagination.range.lowerBound).prefix(pagination.size)),id:\.id) { ReadingOpenQueueRow(store:store,workspace:$0) }
                if documents.count>10 { HStack { Text(pagination.label);Button("上一页") { page = max(0,page-1) }.disabled(pagination.index == 0);Button("下一页") { page += 1 }.disabled(pagination.index>=pagination.last) }.font(.caption) }
            }.padding(.vertical,6)
        }.onChange(of:documents.count) { _,_ in page = pagination.index }
    }
}
struct ReadingOpenQueueRow: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var workspace:Workspace
    var body:some View {
        HStack {
            VStack(alignment:.leading,spacing:3) { Text(workspace.displayName).lineLimit(1).help(workspace.displayName);Text(workspace.openQueueStatus).font(.caption).foregroundStyle(workspace.error == nil ? Color.secondary : .red) }
            Spacer()
            if workspace.isImporting { Button("取消读取") { workspace.cancelImport() } }
            else if workspace.count == 0 { Button(workspace.error == nil ? "读取" : "重试") { workspace.retryOpenFromQueue();store.select(workspace.id) } }
            else { Button("切换阅读") { store.select(workspace.id) } }
        }
    }
}
