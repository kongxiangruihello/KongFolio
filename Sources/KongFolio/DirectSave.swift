import AppKit
import PDFKit

extension Workspace {
    /// OCR source pages and reading metadata need a private recovery copy even when the PDF itself is saved.
    var hasPrivateReadingData: Bool {
        !tableDrafts.isEmpty || wordDraftArchive != nil || !signatureEditArchives.isEmpty || !ocrOriginals.isEmpty || !ocrRegions.isEmpty || !bookmarks.isEmpty || !bibliography.isEmpty
    }
    func scheduleDirectSave() {
        directSaveTask?.cancel()
        guard !AppEnvironment.isTestRun, !saveConflict, dirty, projectURL != nil || sourceURL?.pathExtension.lowercased() == "pdf" else { return }
        directSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.dirty else { return }
            if self.busy || self.drawingInProgress || self.placingSignature != nil { self.scheduleDirectSave(); return }
            _ = self.saveDirectly(askForDestination: false)
        }
    }
    /// Existing documents save without confirmation. A new document asks for a destination only once.
    @discardableResult func saveDirectly(askForDestination: Bool = true) -> Bool {
        guard !busy, count > 0, placingSignature == nil else { return false }
        directSaveTask?.cancel()
        if projectURL != nil { return saveProject(background: false, automatic: !askForDestination) }
        let target: URL
        if let sourceURL, sourceURL.pathExtension.lowercased() == "pdf" { target = sourceURL }
        else {
            guard askForDestination, let chosen = saveURL(type: .pdf, suffix: "pdf") else { return false }
            target = chosen
        }
        do {
            // Protect the unsaved state before attempting the original-file write.
            guard flushRecovery() else { return false }
            let expected = try baseline(for: target)
            try expected.verify(target)
            if !restoringHistory { try DocumentHistory.protectExisting(target, storage: storage) }
            let saved = try expected.writing(target) { try writePDFCopy(to: $0) }
            fileBaseline = saved
            try SignaturePersistence.write(signatureEditArchives, pdf: target, storage: storage)
            sourceURL = target; dirty = false
            fileBaseline = saved; saveConflict = false
            try persistWordDraft(); try persistTableDrafts()
            remember([target]); scheduleRecovery()
            status = "已保存：\(target.lastPathComponent)"
            do {
                var archive = try snapshot(); archive.dirty = false
                try DocumentHistory.record(archive, source: target, storage: storage, label: askForDestination ? "保存 PDF" : "自动保存 PDF", automatic: !askForDestination)
            } catch { status += "；版本记录失败：\(error.localizedDescription)" }
            return true
        } catch {
            handleSaveError(error)
            return false
        }
    }
}

@MainActor enum DocumentPrinting {
    static func printDocument(_ document: PDFDocument) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}

extension WorkspaceStore {
    func printActive() {
        if let workspace = commandWorkspace, !workspace.busy, workspace.count > 0 {
            workspace.showAllLayers()
            DocumentPrinting.printDocument(workspace.document)
        } else if let note = activeNote {
            do { DocumentPrinting.printDocument(try note.renderDocument()) }
            catch { note.error = error.localizedDescription }
        }
    }
}
