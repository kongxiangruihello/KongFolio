import Foundation
import PDFKit

enum ImportPayload { case project(ProjectArchive), documents([Data]) }
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
        busy = true; progress = 0; taskLabel = "读取文件…"
        let worker = Task.detached { try ImportServices.read(urls) }; cancelAuxiliary = { worker.cancel() }
        Task {
            do { let payload = try await worker.value; try Task.checkCancellation(); guard !worker.isCancelled else { throw CancellationError() }; busy = false; cancelAuxiliary = nil; load(urls, insert: insert, prepared: payload) }
            catch is CancellationError { busy = false; cancelAuxiliary = nil; status = "已取消导入" }
            catch { busy = false; cancelAuxiliary = nil; self.error = error.localizedDescription }
        }
    }
}
