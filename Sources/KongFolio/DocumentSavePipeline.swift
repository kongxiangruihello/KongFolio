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
        captureInProgress = true; savePhase = "准备保存"
        defer { captureInProgress = false; savePhase = ""; saveProgress = 0 }
        guard count > 0, !busy, !drawingInProgress, placingSignature == nil else { return false }
        guard dirty || (includePrivateData && hasPrivateReadingData) else { return true }
        guard !saveConflict, let target = historySource else { return false }
        do {
            let identity = target.standardizedFileURL
            let (archive,version,privateVersion,recoveryGeneration) = try await stableSaveSnapshot()
            guard let expected = fileBaseline, expected.path == target.standardizedFileURL.path else { throw FileConflict() }
            let request = DocumentSavePipeline.Request(archive: archive, target: target, expected: expected, storage: storage,
                recovery: recoveryURL, automatic: automatic, restoringHistory: restoringHistory, preparation: savePreparation, recoveryGeneration: recoveryGeneration)
            saving = true; savePhase = "写入文件与阅读资料"; status = "正在后台保存…"; store?.recordActivity("后台保存")
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
            if error is SnapshotOutdated { status = "正在继续编辑，稍后保存最新修改"; scheduleDirectSave() }
            else if error is FileConflict { saveConflict = true; status = error.localizedDescription }
            else if !(error is CancellationError) { self.recordError(error) }
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
        while preparingSnapshot { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 5_000_000) }
        preparingSnapshot = true
        defer { preparingSnapshot = false; if !saving { savePhase = ""; saveProgress = 0 } }
        if let pending = snapshotInFlight {
            if pending.revision == revision { return try await pending.task.value }
            _ = try await pending.task.value
            if snapshotInFlight?.revision == pending.revision { snapshotInFlight = nil }
        }
        if let cachedPDF { return makeArchive(pdf: cachedPDF) }
        guard count > 0 else { throw FolioError(message: "没有可保存的文档") }
        if SnapshotSafety.requiresOriginalSerialization(document) {
            let expected = revision; savePhase = "保留 PDF 交互结构，准备完整快照"
            try await Task.sleep(nanoseconds:1_000_000)
            guard revision == expected else { throw SnapshotOutdated() }
            return try snapshot()
        }
        let version = revision, outline = outlineEntries
        let base = incrementalBase
        let indexes = base != nil && !incrementalPages.isEmpty ? incrementalPages.sorted() : Array(0..<count)
        let full = base == nil || incrementalPages.isEmpty
        var replacements: [(Int,Data)] = []
        savePhase = full ? "准备完整快照" : "准备修改页快照"; saveProgress = 0
        for (offset,index) in indexes.enumerated() {
            try Task.checkCancellation()
            guard revision == version, !drawingInProgress, (0..<count).contains(index) else { throw SnapshotOutdated() }
            // Hidden annotation types are presentation state only. Restore visibility only while this page is copied.
            let hidden = hiddenKinds
            if !hidden.isEmpty { hiddenKinds = []; applyLayers() }
            do { replacements.append((index,try DocumentServices.subset(document,indexes:[index]).dataRepresentation().unwrap("页面快照失败"))) }
            catch { if !hidden.isEmpty { hiddenKinds = hidden; applyLayers() }; throw error }
            if !hidden.isEmpty { hiddenKinds = hidden; applyLayers() }
            saveProgress = Double(offset+1)/Double(indexes.count)
            // Sleep yields the main run loop, including mouse and window events, even for a single very large book.
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard revision == version else { throw SnapshotOutdated() }
        var captured = makeArchive(pdf: base ?? Data())
        let attributes = document.documentAttributes
        let task = Task { [self] () throws -> ProjectArchive in
            savePhase = "后台组装 PDF"
            let data = try await Task.detached(priority: .utility) {
                let copy: PDFDocument
                if !full, let base { copy = try PDFDocument(data: base).unwrap("原始快照无法读取") } else { copy = PDFDocument() }
                var resources: [PDFDocument] = []
                for (index,bytes) in replacements {
                    try Task.checkCancellation()
                    let part = try PDFDocument(data:bytes).unwrap("页面快照无法读取")
                    guard let page = part.page(at:0)?.copy() as? PDFPage else { throw FolioError(message:"页面复制失败") }
                    resources.append(part)
                    if !full { copy.removePage(at:index) }; copy.insert(page,at:index)
                }
                copy.documentAttributes = attributes
                ReadingServices.applyOutline(outline,to:copy)
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

struct SnapshotOutdated: LocalizedError { var errorDescription: String? { "准备期间原书已有新修改，请核对后重试" } }
extension Workspace {
    func stableSaveSnapshot() async throws -> (ProjectArchive,UUID,UUID,Int) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let version = revision, privateVersion = privateDataGeneration, generation = recoverySequence
            do { return (try await snapshotForBackgroundSave(),version,privateVersion,generation) }
            catch is SnapshotOutdated { if attempt == 2 { throw SnapshotOutdated() }; await Task.yield() }
        }
        throw SnapshotOutdated()
    }
}
