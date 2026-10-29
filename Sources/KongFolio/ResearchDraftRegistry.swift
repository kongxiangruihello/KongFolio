import Foundation
@MainActor final class ResearchDraftRegistry {
    static let shared = ResearchDraftRegistry()
    final class Entry { weak var value: ResearchController?; init(_ value:ResearchController) { self.value = value } }
    private var entries: [Entry] = []
    func register(_ controller:ResearchController) { entries.removeAll { $0.value == nil }; if !entries.contains(where: { $0.value === controller }) { entries.append(Entry(controller)) } }
    func flush(storage:URL) -> Bool {
        entries.removeAll { $0.value == nil }; var success = true
        for item in entries { if let controller = item.value, controller.academicStorage?.standardizedFileURL == storage.standardizedFileURL { if !controller.flushAcademicDraft() { success = false } } }; return success
    }
}
