import Foundation
import CoreGraphics

enum ReadingLaunchPolicy:String,CaseIterable {
    case all = "恢复全部标签页",current = "只恢复上次当前文献",empty = "空白启动"
    static let key = "KongFolio.launchPolicy"
    func entries(_ entries:[SessionEntry],selected:String?) -> [SessionEntry] {
        switch self { case .all:return entries;case .current:return entries.filter{$0.slot == selected};case .empty:return [] }
    }
}
extension WorkspaceStore {
    func releaseIdleTabs(now:Date = Date()) {
        let seconds = readingDefaults.object(forKey:"KongFolio.idleTabSeconds") as? Int ?? (AppEnvironment.isTestRun ? 0 : 60)
        guard seconds>0 else { return }
        let partners = Set(tabs.compactMap(\.workspace).compactMap{$0.splitPartner?.id})
        for workspace in tabs.compactMap(\.workspace) where workspace.id != selectedID && !partners.contains(workspace.id) && workspace.canUnload && now.timeIntervalSince(workspace.lastActive)>=Double(seconds) {
            workspace.pendingReadingLayout = workspace.readingLayout
            workspace.unload()
        }
    }
}
extension Workspace {
    var openQueueStatus:String {
        if isImporting { return taskLabel.isEmpty ? "正在读取" : taskLabel }
        if let error { return "读取未完成："+error }
        if count>0 { return "已载入 · \(count) 页" }
        if spilledSession != nil { return "内存已释放，切换时恢复" }
        return needsLoad ? "按需读取，切换时打开" : "读取已取消，可重试"
    }
    func retryOpenFromQueue() {
        guard !busy,count == 0,sourceURL != nil || projectURL != nil else { return }
        error = nil;needsLoad = true;ensureLoaded()
    }
}

enum FunctionToolbarLayout {
    static func columns(width:CGFloat,count:Int) -> Int {
        let capacity = max(1,Int(max(0,width-190)/44)),rows = max(1,Int(ceil(Double(count)/Double(capacity))))
        return max(1,Int(ceil(Double(count)/Double(rows))))
    }
}
