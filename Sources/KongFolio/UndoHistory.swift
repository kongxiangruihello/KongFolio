import Foundation
import PDFKit

/// Stable identity for annotations. The value is stored in the annotation dictionary, so it
/// survives serialization and lets undo entries find "the same" annotation after a reload.
enum AnnotationIdentity {
    static let key = PDFAnnotationKey(rawValue: "KongFolioID")

    static func id(of annotation: PDFAnnotation) -> String {
        if let existing = annotation.value(forAnnotationKey: key) as? String, !existing.isEmpty { return existing }
        let id = UUID().uuidString
        annotation.setValue(id, forAnnotationKey: key)
        return id
    }

    static func copy(_ annotation: PDFAnnotation, id: String) -> PDFAnnotation? {
        guard let copy = annotation.copy() as? PDFAnnotation else { return nil }
        copy.setValue(id, forAnnotationKey: key)
        return copy
    }

    static func find(_ id: String, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { ($0.value(forAnnotationKey: key) as? String) == id }
    }
}

/// One annotation before and after an edit; `nil` means "not present".
struct AnnotationChange {
    let page: Int
    let id: String
    let before: PDFAnnotation?
    let after: PDFAnnotation?
}

/// An annotation captured before an interactive edit (move, resize, text change, delete).
struct PendingAnnotationEdit {
    let page: Int
    let id: String
    let before: PDFAnnotation
}

/// Undo history mixes cheap annotation-level entries with full snapshots. Annotation edits —
/// the most frequent operations — no longer serialize the whole PDF; page-structure operations
/// still use snapshots because they replace many objects at once.
enum UndoEntry {
    case snapshot(ProjectArchive)
    case annotations([AnnotationChange])

    var snapshotBytes: Int {
        guard case .snapshot(let archive) = self else { return 0 }
        return archive.pdf.count + archive.recipes.values.reduce(0) { $0 + $1.originalPDF.count } + (archive.signatureEdits ?? [:]).values.reduce(0) { $0 + $1.base.count + $1.items.reduce(0) { $0 + $1.png.count } }
    }
    var isSnapshot: Bool { if case .snapshot = self { return true } else { return false } }
}

extension Workspace {
    static let maximumUndoEntries = 100
    static let maximumSnapshots = 20
    static let snapshotBudget = 192 * 1024 * 1024

    func pushUndo(_ entry: UndoEntry) {
        history.append(entry)
        while history.count > 1, history.count > Workspace.maximumUndoEntries
                || history.filter(\.isSnapshot).count > Workspace.maximumSnapshots
                || history.reduce(0, { $0 + $1.snapshotBytes }) > Workspace.snapshotBudget {
            history.removeFirst()
        }
        future.removeAll()
        dirty = true
    }

    /// Records annotations that were just added to their pages.
    func recordAnnotationsAdded(_ annotations: [PDFAnnotation]) {
        let changes = annotations.compactMap { annotation -> AnnotationChange? in
            guard let page = annotation.page else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            let id = AnnotationIdentity.id(of: annotation)
            return AnnotationChange(page: index, id: id, before: nil, after: AnnotationIdentity.copy(annotation, id: id))
        }
        guard !changes.isEmpty else { return }
        pushUndo(.annotations(changes))
        edited(pages: Set(changes.map(\.page)))
    }

    /// Captures annotations before they are changed or removed.
    func beginAnnotationEdit(_ annotations: [PDFAnnotation]) -> [PendingAnnotationEdit] {
        annotations.compactMap { annotation in
            guard let page = annotation.page else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            let id = AnnotationIdentity.id(of: annotation)
            guard let before = AnnotationIdentity.copy(annotation, id: id) else { return nil }
            return PendingAnnotationEdit(page: index, id: id, before: before)
        }
    }

    /// Stores the edit started with `beginAnnotationEdit`, reading the current state from the page.
    func commitAnnotationEdit(_ edits: [PendingAnnotationEdit]) {
        let changes = edits.map { edit -> AnnotationChange in
            let current = document.page(at: edit.page).flatMap { AnnotationIdentity.find(edit.id, on: $0) }
            return AnnotationChange(page: edit.page, id: edit.id, before: edit.before, after: current.flatMap { AnnotationIdentity.copy($0, id: edit.id) })
        }
        guard !changes.isEmpty else { return }
        pushUndo(.annotations(changes))
        edited(pages: Set(changes.map(\.page)))
    }

    func applyAnnotationChanges(_ changes: [AnnotationChange], restoringBefore: Bool) {
        for change in restoringBefore ? changes.reversed() : changes {
            guard let page = document.page(at: change.page) else { continue }
            if let current = AnnotationIdentity.find(change.id, on: page) { page.removeAnnotation(current) }
            if let state = restoringBefore ? change.before : change.after, let copy = AnnotationIdentity.copy(state, id: change.id) {
                page.addAnnotation(copy)
            }
        }
        selectedAnnotation = nil
        dirty = true
        edited(pages: Set(changes.map(\.page)))
    }

    /// Serializes the current state for the opposite undo stack. A failure used to be swallowed with `try?`,
    /// which silently dropped the redo step; now the undo/redo is refused and the user is told why.
    private func snapshotForHistory(_ action: String) -> ProjectArchive? {
        do { return try snapshot() }
        catch {
            self.error = "无法\(action)：当前文档无法序列化，操作已取消，文档保持不变。\(error.localizedDescription)"
            return nil
        }
    }

    func undo() {
        guard let entry = history.last else { return }
        switch entry {
        case .snapshot(let archive):
            guard let current = snapshotForHistory("撤销") else { return }
            history.removeLast()
            future.append(.snapshot(current))
            report { try restore(archive, keepProjectURL: true); dirty = true; scheduleRecovery() }
        case .annotations(let changes):
            history.removeLast()
            applyAnnotationChanges(changes, restoringBefore: true)
            future.append(entry)
        }
    }

    func redo() {
        guard let entry = future.last else { return }
        switch entry {
        case .snapshot(let archive):
            guard let current = snapshotForHistory("重做") else { return }
            future.removeLast()
            history.append(.snapshot(current))
            report { try restore(archive, keepProjectURL: true); dirty = true; scheduleRecovery() }
        case .annotations(let changes):
            future.removeLast()
            applyAnnotationChanges(changes, restoringBefore: false)
            history.append(entry)
        }
    }
}
