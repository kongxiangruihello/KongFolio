import Foundation

extension WorkspaceStore {
    func sampleRuntimeMemory(resident: Int? = nil) {
        residentMemoryMB = resident ?? RuntimeMemory.residentMB()
        constrainedMemory = RuntimeMemory.constrained(resident: residentMemoryMB,budget:memoryBudgetMB,wasConstrained:constrainedMemory)
        documentTasks.maximumActive = constrainedMemory ? 1 : 2
        OCRResourceGate.shared.setMaximum(constrainedMemory ? 1 : 2)
        Task { await ImportLimiter.shared.setMaximum(constrainedMemory ? 1 : 2) }
        releaseIdleTabs(); loadedTabsChanged(); recordActivity("内存采样")
    }
    func restoreStartup(_ entry: SessionEntry) throws {
        guard startupEntries.contains(where: { $0.slot == entry.slot }) else { return }
        let w = Workspace(storage:storage,slot:entry.slot,readingDefaults:readingDefaults); w.store = self
        w.readingBatchEntryID = entry.readingBatchEntryID
        let protection = StartupProtection(storage:storage)
        let token = UUID()
        if startupSafetyEnabled { protection.trackImport(token,path:entry.path ?? "恢复副本：" + entry.slot) }
        w.bootstrap()
        if startupSafetyEnabled { protection.trackImport(token,path:nil) }
        if w.count == 0 {
            guard entry.kind != .recovery, let path = entry.path else { throw FolioError(message:"恢复副本未能打开，已保留，可从恢复中心查看") }
            let url = URL(fileURLWithPath:path)
            if entry.kind == .project { w.projectURL = url } else { w.sourceURL = url }
            let progress = ReadingProgress.load(path:path,defaults:readingDefaults)
            w.needsLoad = true
            w.pendingView = progress.resumePosition(pageCount:progress.pages) ?? entry.position
            w.pendingReadingLayout = progress.layout ?? entry.layout
        }
        showStartupReview = false
        tabsForStartup(w)
        startupEntries.removeAll { $0.slot == entry.slot }
        if pendingStartupSelected == entry.slot { pendingStartupSelected = nil }
        if startupEntries.isEmpty { try StartupProtection(storage:storage).finishReview(excluding:[]); showStartupReview = false }
        saveSession()
    }
    func startupPage(_ entry: SessionEntry) -> Int? {
        if let path = entry.path {
            let saved = ReadingProgress.load(path:path,defaults:readingDefaults)
            if let position = saved.resumePosition(pageCount:saved.pages) { return position.selection + 1 }
        }
        return entry.position.map { $0.selection + 1 }
    }

    func startupInterruptionCount(_ entry: SessionEntry) -> Int {
        startupSuspects[entry.path ?? ("恢复副本：" + entry.slot)] ?? 0
    }

    func deferStartupReview() { showStartupReview = false; saveSession() }
    func skipStartupEntries() throws {
        try StartupProtection(storage:storage).finishReview(excluding:Set(startupEntries.map(\.slot)))
        startupEntries = []; pendingStartupSelected = nil; showStartupReview = false; saveSession()
    }
}
