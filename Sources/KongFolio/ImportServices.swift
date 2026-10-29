import Foundation
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
            let data = try Data(contentsOf: url)
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
                throw FolioError(message: "无法打开 PDF，文件可能损坏或需要密码。")
            }
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
    func startImport(_ urls: [URL], insert: Bool) {
        store?.recordActivity("准备打开文件")
        isImporting = true; busy = true; progress = 0; taskLabel = "读取文件…"
        let root = storage
        let worker = Task.detached { () async throws -> (ImportPayload, PreparedReading?) in
            try await CloudFilePreparation.prepare(urls) { phase in Task { @MainActor [weak self] in self?.taskLabel = phase } }
            await MainActor.run { [weak self] in self?.taskLabel = "等候文件解析…" }
            try await ImportLimiter.shared.acquire()
            defer { Task { await ImportLimiter.shared.release() } }
            await MainActor.run { [weak self] in self?.taskLabel = "正在解析文件…" }
            let payload = try ImportServices.read(urls)
            let reading: PreparedReading?
            if !insert, urls.count == 1, urls[0].pathExtension.lowercased() == "pdf", case .documents(let bytes) = payload {
                reading = try PreparedReading.read(urls[0], bytes: bytes[0], storage: root)
            } else { reading = nil }
            try Task.checkCancellation()
            return (payload, reading)
        }; cancelAuxiliary = { worker.cancel() }
        Task {
            do { let (payload, reading) = try await worker.value; try Task.checkCancellation(); guard !worker.isCancelled else { throw CancellationError() }; isImporting = false; busy = false; cancelAuxiliary = nil; load(urls, insert: insert, prepared: payload, reading: reading) }
            catch is CancellationError { isImporting = false; busy = false; cancelAuxiliary = nil; status = "已取消导入" }
            catch { isImporting = false; busy = false; cancelAuxiliary = nil; self.error = error.localizedDescription }
        }
    }
}
