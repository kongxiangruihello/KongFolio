import Foundation

extension WorkspaceStore {
    func sampleRuntimeMemory(resident: Int? = nil) {
        residentMemoryMB = resident ?? RuntimeMemory.residentMB()
        constrainedMemory = RuntimeMemory.constrained(resident: residentMemoryMB,budget:memoryBudgetMB,wasConstrained:constrainedMemory)
        documentTasks.maximumActive = constrainedMemory ? 1 : 2
        OCRResourceGate.shared.setMaximum(constrainedMemory ? 1 : 2)
        Task { await ImportLimiter.shared.setMaximum(constrainedMemory ? 1 : 2) }
        loadedTabsChanged(); recordActivity("内存采样")
    }
    func restoreStartup(_ entry: SessionEntry) throws {
        guard startupEntries.contains(where: { $0.slot == entry.slot }) else { return }
        let w = Workspace(storage:storage,slot:entry.slot,readingDefaults:readingDefaults); w.store = self
        StartupProtection(storage:storage).opening(entry.path ?? "恢复副本：" + entry.slot)
        w.bootstrap()
        if w.count == 0 {
            guard entry.kind != .recovery, let path = entry.path else { throw FolioError(message:"恢复副本未能打开，已保留，可从恢复中心查看") }
            let url = URL(fileURLWithPath:path)
            guard FileManager.default.fileExists(atPath:path) else { throw FolioError(message:"原文件缺失，请在书架重新定位") }
            if entry.kind == .project { w.projectURL = url } else { w.sourceURL = url }
            w.needsLoad = true; w.pendingView = entry.position; w.pendingReadingLayout = entry.layout
        }
        tabsForStartup(w)
        startupEntries.removeAll { $0.slot == entry.slot }
        if startupEntries.isEmpty { try StartupProtection(storage:storage).finishReview(excluding:[]); showStartupReview = false }
        saveSession()
    }
    func deferStartupReview() { showStartupReview = false; saveSession() }
    func skipStartupEntries() throws {
        try StartupProtection(storage:storage).finishReview(excluding:Set(startupEntries.map(\.slot)))
        startupEntries = []; showStartupReview = false; saveSession()
    }
}
