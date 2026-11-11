import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let kongFolioPDFExcerpt = UTType(exportedAs:"com.kongfolio.pdf-excerpt-drag",conformingTo:.data)
}

struct PDFExcerptDrag {
    let token = UUID()
    let workspaceID: UUID
    let record: ReadingRecord

    @MainActor func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(token.uuidString.utf8),forType:NSPasteboard.PasteboardType(UTType.kongFolioPDFExcerpt.identifier))
        item.setString(record.quote,forType:.string)
        return item
    }
}

@MainActor final class PDFExcerptDragSource: NSObject, NSDraggingSource {
    weak var store: WorkspaceStore?
    let token: UUID

    init(store: WorkspaceStore, token: UUID) {
        self.store = store
        self.token = token
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let store else { return }
        if operation.isEmpty { store.cancelPDFExcerptDrag(token); return }
        // A SwiftUI destination loads the pasteboard data after the native session ends.
        Task { @MainActor [weak store] in
            try? await Task.sleep(nanoseconds:10_000_000_000)
            store?.cancelPDFExcerptDrag(token)
        }
    }
}

extension WorkspaceStore {
    var acceptsPDFExcerptDrop: Bool {
        showReadingDesk && readingDeskSection == .excerpts && !journal.unreadable
    }

    func beginPDFExcerptDrag(_ record: ReadingRecord, from workspace: Workspace) -> PDFExcerptDrag? {
        guard acceptsPDFExcerptDrop, workspace.store === self, record.kind == .excerpt,
              !record.quote.isEmpty, !record.citations.isEmpty else { return nil }
        let drag = PDFExcerptDrag(workspaceID:workspace.id,record:record)
        pendingPDFExcerptDrag = drag
        return drag
    }

    @discardableResult
    func acceptPDFExcerptDrop(_ token: UUID) -> Bool {
        guard let drag = pendingPDFExcerptDrag, drag.token == token else { return false }
        pendingPDFExcerptDrag = nil
        guard acceptsPDFExcerptDrop,
              let workspace = tabs.compactMap(\.workspace).first(where:{ $0.id == drag.workspaceID }) else { return false }
        saveReadingExcerpt(drag.record)
        workspace.status = "已拖入摘录，保留原文出处"
        return true
    }

    func cancelPDFExcerptDrag(_ token: UUID) {
        if pendingPDFExcerptDrag?.token == token { pendingPDFExcerptDrag = nil }
    }
}
