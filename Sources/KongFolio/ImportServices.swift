import Foundation
import PDFKit

enum ImportPayload { case project(ProjectArchive), documents([Data]) }
enum ImportServices {
    static func read(_ urls: [URL]) throws -> ImportPayload {
        if urls.contains(where: { $0.pathExtension.lowercased() == "kongfolio" }) {
            guard urls.count == 1 else { throw FolioError(message: "请单独打开 KongFolio 项目") }
            try Task.checkCancellation(); return .project(try ProjectArchive.read(urls[0]))
        }
        var results: [Data] = []
        for url in urls { try Task.checkCancellation(); let data = try autoreleasepool { try DocumentServices.load(url).dataRepresentation().unwrap("文档读取失败") }; results.append(data) }
        try Task.checkCancellation(); return .documents(results)
    }
}
extension Workspace {
    func startImport(_ urls: [URL], insert: Bool, scanAfter: Bool) {
        busy = true; progress = 0; taskLabel = "读取文件…"
        let worker = Task.detached { try ImportServices.read(urls) }; cancelAuxiliary = { worker.cancel() }
        Task {
            do { let payload = try await worker.value; try Task.checkCancellation(); guard !worker.isCancelled else { throw CancellationError() }; busy = false; cancelAuxiliary = nil; load(urls, insert: insert, scanAfter: scanAfter, prepared: payload) }
            catch is CancellationError { busy = false; cancelAuxiliary = nil; status = "已取消导入" }
            catch { busy = false; cancelAuxiliary = nil; self.error = error.localizedDescription }
        }
    }
}
