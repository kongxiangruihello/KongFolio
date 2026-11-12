import Foundation
import Combine

@MainActor final class ReadingIncrementalController:ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var folder:URL?
    @Published private(set) var message = ""
    private var task:Task<Void,Never>?
    func start(_ state:ReadingJournalState,old:ReadingExportLedger?,options:ReadingExportOptions,formats:[ReadingRecordExport.Format],assets:URL,journalFolder:URL,parent:URL) {
        guard !busy else { return };busy = true;message = "正在导出新增与修改内容…"
        task = Task { do { folder = try await ReadingIncrementalWorker.shared.export(state,old:old,options:options,formats:formats,assets:assets,journalFolder:journalFolder,parent:parent);message = "导出完成，增量基准已更新；修改期间新产生的变化会留到下一次" } catch { message = FolioCancellation.matches(error) ? "已取消，增量基准未更新" : error.localizedDescription };busy = false;task = nil }
    }
    func cancel() { task?.cancel() }
    func stopAndWait() async { task?.cancel();await task?.value }
}
extension WorkspaceStore {
    func openReadingReference(_ reference:ReadingReference) {
        guard let item = reference.item, !reference.removed else { return }
        openReadingItem(item)
        if let target = reference.target { readingDetailRequest = ReadingDetailRequest(item:item,target:target) }
    }

    func openReadingItem(_ item:ReadingLibraryID) {
        readingDetailRequest = nil
        readingLibraryNavigation = item;readingLibraryNavigationRequest = UUID()
        switch item { case .record(let id):readingRecordID = id;case .essay(let id):journal.selectEssay(id) }
        openReadingDesk(.search,window:true)
    }
}
extension ReadingReference {
    var item:ReadingLibraryID? { if let destination { return destination };let parts = id.split(separator:":",maxSplits:1);guard parts.count == 2,let uuid = UUID(uuidString:String(parts[1])) else { return nil };return parts[0] == "essay" ? .essay(uuid) : .record(uuid) }
}
