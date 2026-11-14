import AppKit
import Foundation
import UniformTypeIdentifiers
import PDFKit

enum ImportPayload { case project(ProjectArchive), documents([Data]) }
/// Prepared on the file reader worker, including hashes and private record validation.
struct PreparedReading {
    var baseline: FileBaseline
    var companion: ProjectArchive?
    var signatures: [Int: SignatureEditArchive]
    var warning: String?
    static func read(_ source: URL, bytes: Data, storage: URL) throws -> Self {
        let baseline = try FileBaseline.capture(source, data: bytes)
        var companion: ProjectArchive?, warning: String?
        do { companion = try ReadingDocumentStore.read(source: source, pdf: bytes, storage: storage) }
        catch { warning = error.localizedDescription }
        let signatures = companion?.signatureEdits ?? SignaturePersistence.read(pdf: source, bytes: bytes, storage: storage)
        return Self(baseline: baseline, companion: companion, signatures: signatures, warning: warning)
    }
}
enum ImportServices {
    /// A PDF is used byte for byte. Loading it and calling `dataRepresentation()` rewrote the whole file
    /// (seconds for a book of several hundred pages) only to produce the same pages again.
    static func documentData(_ url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "pdf" {
            let checked=try PDFImportProbe053.inspect(url)
            let data = try Data(contentsOf: url)
            guard OCRPageCache.digest(data)==checked.digest else { throw FolioError(message:"PDF 在检查期间发生变化，请重新打开") }
            return data
        }
        return try DocumentServices.load(url).dataRepresentation().unwrap("文档读取失败")
    }
    static func read(_ urls: [URL]) throws -> ImportPayload {
        if urls.contains(where: { $0.pathExtension.lowercased() == "kongfolio" }) {
            guard urls.count == 1 else { throw FolioError(message: "请单独打开 KongFolio 项目") }
            try Task.checkCancellation()
            let baseline = try FileBaseline.capture(urls[0])
            var archive = try ProjectArchive.read(urls[0])
            try baseline.verify(urls[0]); archive.fileBaseline = baseline
            return .project(archive)
        }
        var results: [Data] = []
        for url in urls { try Task.checkCancellation(); let data = try autoreleasepool { try documentData(url) }; results.append(data) }
        try Task.checkCancellation(); return .documents(results)
    }
}
extension Workspace {
    /// Detach cancelled reads immediately; their eventual results must not mutate a reused tab.
    func cancelImport() {
        guard isImporting else { return }
        if store?.startupSafetyEnabled == true {
            StartupProtection(storage:storage).trackImport(importGeneration,path:nil)
        }
        importGeneration = UUID()
        let cancel = cancelAuxiliary;cancelAuxiliary = nil;cancel?()
        isImporting = false;busy = false;progress = 0;taskLabel = "";status = "已取消读取，可关闭或重试"
    }
    func startImport(_ urls:[URL],insert:Bool) {
        store?.recordActivity("准备打开文件")
        let generation = UUID();importGeneration = generation
        let protection = store?.startupSafetyEnabled == true ? StartupProtection(storage:storage) : nil
        protection?.trackImport(generation,path:urls.first?.path)
        store?.scheduleSessionSave()
        isImporting = true;busy = true;progress = 0;taskLabel = "读取文件…"
        let root = storage
        let prepare = prepareImportFiles
        let worker = Task.detached { () async throws -> (ImportPayload,PreparedReading?) in
            for url in urls where ShelfFileStatus.read(url) == .missing { throw ReadingOpenFailure.missing }
            let fromCloud = urls.contains { ShelfFileStatus.read($0) == .cloud }
            do {
                try await prepare(urls) { phase in Task { @MainActor [weak self] in guard let self,self.importGeneration == generation else { return };if self.taskLabel != phase { self.store?.recordActivity(phase) };self.taskLabel = phase } }
            } catch where fromCloud && !FolioCancellation.matches(error) {
                throw ReadingOpenFailure.cloud(error.localizedDescription)
            }
            await MainActor.run { [weak self] in guard let self,self.importGeneration == generation else { return };self.taskLabel = "等候文件解析…" }
            try await ImportLimiter.shared.acquire();defer { Task { await ImportLimiter.shared.release() } }
            await MainActor.run { [weak self] in guard let self,self.importGeneration == generation else { return };self.taskLabel = "正在解析文件…";self.store?.recordActivity("正在解析 PDF 或文档") }
            let payload = try ImportServices.read(urls)
            let reading:PreparedReading?
            if !insert,urls.count == 1,urls[0].pathExtension.lowercased() == "pdf",case .documents(let bytes) = payload { reading = try PreparedReading.read(urls[0],bytes:bytes[0],storage:root) } else { reading = nil }
            try Task.checkCancellation();return (payload,reading)
        }
        cancelAuxiliary = { worker.cancel() }
        Task {
            defer { protection?.trackImport(generation,path:nil); store?.scheduleSessionSave() }
            do {
                let (payload,reading) = try await worker.value;try Task.checkCancellation()
                guard importGeneration == generation,!worker.isCancelled else { return }
                isImporting = false;busy = false;cancelAuxiliary = nil
                store?.recordActivity("载入已解析的文档")
                let started = ProcessInfo.processInfo.systemUptime
                load(urls,insert:insert,prepared:payload,reading:reading)
                let duration = ProcessInfo.processInfo.systemUptime - started
                store?.recordActivity("完成界面文档载入",elapsedMilliseconds:Int(duration * 1_000))
                if !insert {
                    let failure = count == 0 ? error.map{FolioError(message:$0)} : nil
                    store?.recordBatchLoad(self,error:failure)
                }
            } catch {
                guard importGeneration == generation else { return }
                isImporting = false;busy = false;cancelAuxiliary = nil
                if FolioCancellation.matches(error) { status = "已取消导入" } else { recordError(error); if !insert { store?.recordBatchLoad(self,error:error) } }
            }
        }
    }
}

extension Workspace {
    func choosePageImage() {
        guard !busy, !readingLocked, placingSignature == nil, let page, let view = pdfView else { return }
        guard !DocumentOpenPanel.coordinator.revealExisting() else { return }
        let panel = NSOpenPanel()
        DocumentOpenPanel.configure(panel)
        panel.allowedContentTypes = [.image]
        panel.message = "选取一张图片，在当前 PDF 页面中调整位置和大小。"
        DocumentOpenPanel.coordinator.present(panel,preferred:view.window) { [weak self,weak page] _,urls in
            guard let url = urls.first, let page else { return }
            self?.preparePageImage(url,on:page)
        }
    }

    private func preparePageImage(_ url: URL, on page: PDFPage) {
        guard !busy, !readingLocked, placingSignature == nil, self.page === page else { return }
        let generation = UUID()
        importGeneration = generation
        isImporting = true
        busy = true
        progress = 0
        taskLabel = "读取图片…"
        let worker = Task.detached(priority:.userInitiated) { [weak self] in
            try await CloudFilePreparation.prepare([url]) { phase in
                Task { @MainActor [weak self] in
                    guard let self, self.importGeneration == generation else { return }
                    self.taskLabel = phase
                }
            }
            try Task.checkCancellation()
            let image = try SignatureImage.load(url).unwrap("无法读取图片："+url.lastPathComponent)
            let bytes = try SignatureImage.pngData(image).unwrap("无法处理图片："+url.lastPathComponent)
            try Task.checkCancellation()
            return (image,bytes)
        }
        cancelAuxiliary = { worker.cancel() }
        Task {
            let result = await worker.result
            guard importGeneration == generation else { return }
            isImporting = false
            busy = false
            cancelAuxiliary = nil
            taskLabel = ""
            do {
                let (image,bytes) = try result.get()
                guard self.page === page, pdfView != nil else {
                    status = "页面已切换，请在要插入图片的页面重试。"
                    return
                }
                beginPlacingPageImage(image,png:bytes,on:page)
            } catch { recordError(error) }
        }
    }
}
