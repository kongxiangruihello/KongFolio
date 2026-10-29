import Foundation
import PDFKit

/// File coordination, hashing, recovery and version archives run on a serial worker, using immutable bytes only.
/// PDFKit's live document remains owned by the main actor.
enum DocumentSavePipeline {
    struct Request {
        var archive: ProjectArchive
        let target: URL
        let expected: FileBaseline
        let storage: URL
        let recovery: URL
        let automatic: Bool
        let restoringHistory: Bool
        var preparation: (@Sendable () throws -> Void)? = nil
        var recoveryGeneration: Int? = nil
    }
    struct Outcome {
        let baseline: FileBaseline
        let companionError: Error?
        let historyError: Error?
    }
    private static let queue = DispatchQueue(label: "com.kongfolio.document-save", qos: .utility)
    static func write(_ request: Request) throws -> Outcome { try queue.sync { try perform(request) } }
    private static func perform(_ request: Request) throws -> Outcome {
        try request.preparation?()
        var archive = request.archive
        try RecoveryWriter.shared.flush(archive, to: request.recovery, generation: request.recoveryGeneration)
        try request.expected.verify(request.target)
        if !request.restoringHistory { try DocumentHistory.protectExisting(request.target, storage: request.storage) }
        let project = request.target.pathExtension.lowercased() == "kongfolio"
        archive.dirty = false
        if project { archive.projectPath = request.target.path }
        let baseline = try request.expected.writing(request.target) { target in
            let staging = target.deletingLastPathComponent().appendingPathComponent(".KongFolio-save-" + UUID().uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: staging) }
            if project { try archive.write(staging) } else { try archive.pdf.write(to: staging) }
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: target) }
        }
        archive.fileBaseline = baseline
        var companionError: Error?, historyError: Error?
        if !project {
            do { try ReadingDocumentStore.write(archive, source: request.target, storage: request.storage)
                 try SignaturePersistence.write(archive.signatureEdits ?? [:], pdf: request.target, storage: request.storage) }
            catch { companionError = error }
        }
        do { try DocumentHistory.record(archive, source: request.target, storage: request.storage,
                label: request.automatic ? "自动保存" : "保存文档", automatic: request.automatic) }
        catch { historyError = error }
        return Outcome(baseline: baseline, companionError: companionError, historyError: historyError)
    }
}

extension Workspace {
    /// A running disk write is never cancelled by a new keystroke. The next save captures the newer revision.
    @discardableResult func saveInBackground(automatic: Bool = true, includePrivateData: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        while captureInProgress {
            if Task.isCancelled { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
        while let saveWorker { if !(await saveWorker.value) { return false } }
        captureInProgress = true
        defer { captureInProgress = false }
        guard count > 0, !busy, !drawingInProgress, placingSignature == nil else { return false }
        guard dirty || (includePrivateData && hasPrivateReadingData) else { return true }
        guard !saveConflict, let target = historySource else { return false }
        do {
            let version = revision, privateVersion = privateDataGeneration, recoveryGeneration = recoverySequence, identity = target.standardizedFileURL
            let archive = try await snapshotForBackgroundSave()
            guard let expected = fileBaseline, expected.path == target.standardizedFileURL.path else { throw FileConflict() }
            let request = DocumentSavePipeline.Request(archive: archive, target: target, expected: expected, storage: storage,
                recovery: recoveryURL, automatic: automatic, restoringHistory: restoringHistory, preparation: savePreparation, recoveryGeneration: recoveryGeneration)
            saving = true; status = "正在后台保存…"; store?.recordActivity("后台保存")
            let task = Task { [self] () -> Bool in
                defer { saving = false; saveWorker = nil; store?.loadedTabsChanged() }
                do {
                    let result = try await Task.detached(priority: .utility) { try DocumentSavePipeline.write(request) }.value
                    guard historySource?.standardizedFileURL == identity else { return false }
                    fileBaseline = result.baseline
                    if let failure = result.companionError {
                        dirty = true; error = "PDF 已保存，阅读资料仍在恢复副本中：" + failure.localizedDescription
                        return false
                    }
                    saveConflict = false
                    if revision == version { dirty = false }
                    status = result.historyError.map { "文件已保存，版本记录失败：" + $0.localizedDescription } ?? "已保存：" + target.lastPathComponent
                    let privateUnchanged = privateDataGeneration == privateVersion
                    scheduleRecovery()
                    if dirty { scheduleDirectSave() }
                    closePrepared = !dirty && privateUnchanged
                    return true
                } catch {
                    if error is FileConflict { saveConflict = true; status = error.localizedDescription }
                    else { self.error = "保存失败，修改仍保留：" + error.localizedDescription }
                    return false
                }
            }
            saveWorker = task
            return await task.value
        } catch {
            if error is FileConflict { saveConflict = true; status = error.localizedDescription }
            else { self.error = error.localizedDescription }
            return false
        }
    }

    /// A close must include edits made while an earlier save was in flight.
    func finishPendingSave() async -> Bool {
        closingInProgress = true
        defer { closingInProgress = false }
        directSaveTask?.cancel()
        if let saveWorker, !(await saveWorker.value) { return false }
        while dirty {
            guard historySource != nil else { return saveDirectly() }
            guard await saveInBackground(automatic: false) else { return false }
        }
        while hasPrivateReadingData && !closePrepared {
            guard await saveInBackground(automatic: false, includePrivateData: true) else { return false }
        }
        return true
    }
}

extension Workspace {
    /// Only changed pages touch the live PDF. The independent original bytes are assembled on a worker.
    func snapshotForBackgroundSave() async throws -> ProjectArchive {
        if let pending = snapshotInFlight {
            if pending.revision == revision { return try await pending.task.value }
            _ = try await pending.task.value
            if snapshotInFlight?.revision == pending.revision { snapshotInFlight = nil }
        }
        guard cachedPDF == nil, let base = incrementalBase, !incrementalPages.isEmpty else { return try snapshot() }
        let version = revision
        let hidden = hiddenKinds
        if !hidden.isEmpty { hiddenKinds = []; applyLayers() }
        let replacements: [(Int, Data)]
        do {
            replacements = try incrementalPages.sorted().map { index in
                guard (0..<count).contains(index) else { throw FolioError(message: "保存页码已变化") }
                return (index, try DocumentServices.subset(document, indexes: [index]).dataRepresentation().unwrap("页面快照失败"))
            }
        } catch { if !hidden.isEmpty { hiddenKinds = hidden; applyLayers() }; throw error }
        if !hidden.isEmpty { hiddenKinds = hidden; applyLayers() }
        var captured = makeArchive(pdf: base)
        let outline = outlineEntries
        let task = Task { [self] () throws -> ProjectArchive in
            let data = try await Task.detached(priority: .utility) {
            let copy = try PDFDocument(data: base).unwrap("原始快照无法读取")
            var resources: [PDFDocument] = []
            for (index, bytes) in replacements {
                let part = try PDFDocument(data: bytes).unwrap("页面快照无法读取")
                guard let page = part.page(at: 0)?.copy() as? PDFPage else { throw FolioError(message: "页面复制失败") }
                resources.append(part)
                copy.removePage(at: index); copy.insert(page, at: index)
            }
            ReadingServices.applyOutline(outline, to: copy)
            return try withExtendedLifetime(resources) { try copy.dataRepresentation().unwrap("保存快照失败") }
        }.value
            captured.pdf = data
            if revision == version { cachedPDF = data; incrementalBase = nil; incrementalPages = [] }
            return captured
        }
        snapshotInFlight = (version,task)
        defer { if snapshotInFlight?.revision == version { snapshotInFlight = nil } }
        return try await task.value
    }
}
