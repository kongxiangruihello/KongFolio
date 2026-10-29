import AppKit
import PDFKit

struct ResearchSourceBinding: Codable {
    var digest: String
    var pages: [String]
    static func make(_ bytes: Data, digest: String) throws -> Self {
        let doc = try PDFDocument(data:bytes).unwrap("无法核对来源 PDF")
        guard !doc.isLocked else { throw FolioError(message:"来源需要解锁") }
        let pages = try (0..<doc.pageCount).map { index -> String in
            try Task.checkCancellation()
            return try autoreleasepool {
                let page = try doc.page(at:index).unwrap("来源页面失效")
                // Ignore annotations so normal highlighting does not invalidate page relationships.
                for annotation in page.annotations { page.removeAnnotation(annotation) }
                let image = try DocumentServices.render(page,maxDimension:64)
                let data = try SignatureImage.pngData(image).unwrap("来源页面无法核对")
                let geometry = NSStringFromRect(page.bounds(for:.mediaBox)) + NSStringFromRect(page.bounds(for:.cropBox)) + String(page.rotation)
                return OCRPageCache.digest(data + Data((geometry + (page.string ?? "")).utf8))
            }
        }
        return Self(digest:digest,pages:pages)
    }
    func samePages(_ other: Self) -> Bool { pages == other.pages }
}

extension ResearchStore {
    func warning(path: String) -> String? { sourceWarnings.first { ReadingProgress.canonicalPath($0.key) == ReadingProgress.canonicalPath(path) }?.value }
    func setWarning(path: String, message: String?) { sourceWarnings[path] = message }
    func bind(path: String, value: ResearchSourceBinding) throws {
        try update { if $0.bindings == nil { $0.bindings = [:] }; $0.bindings?[path] = value }
        setWarning(path:path,message:nil)
    }
    func binding(path: String) -> ResearchSourceBinding? { state.bindings?.first { ReadingProgress.canonicalPath($0.key) == ReadingProgress.canonicalPath(path) }?.value }
    func validateSource(path: String, bytes: Data, digest: String) async {
        guard state.labels.keys.contains(where: { ReadingProgress.canonicalPath($0) == ReadingProgress.canonicalPath(path) }) || state.editions.contains(where: { $0.contains(path) }) else { return }
        guard let saved = binding(path:path) else {
            let expected = state.identities?.first { ReadingProgress.canonicalPath($0.key) == ReadingProgress.canonicalPath(path) }?.value
            if expected != nil && expected != digest { setWarning(path:path,message:"原文件版本已变化，请核对书签、页码、版本锚点及整理草稿后确认关联") }
            return
        }
        guard saved.digest != digest else { return }
        setWarning(path:path,message:"正在核对原文件变化，页码对应和锚点暂不套用")
        do {
            let current = try await Task.detached(priority:.utility) { try ResearchSourceBinding.make(bytes,digest:digest) }.value
            guard binding(path:path)?.digest == saved.digest else { return }
            if saved.samePages(current) { try bind(path:path,value:current) }
            else { setWarning(path:path,message:"原文件的页面内容、页数、方向或裁边已变化；旧页码、版本锚点和草稿保留，请核对后重新关联") }
        } catch { setWarning(path:path,message:"来源核对未完成：" + error.localizedDescription) }
    }
}
extension Workspace {
    func validateResearchSource() {
        guard let store, let path = displayPath, let bytes = cachedPDF else { return }
        let digest = fileBaseline?.digest ?? OCRPageCache.digest(bytes)
        Task { await store.research.validateSource(path:path,bytes:bytes,digest:digest) }
    }
}
extension WorkspaceStore {
    func checkOpenSourceChanges() {
        let items = tabs.compactMap(\.workspace).compactMap { w -> (String,FileBaseline)? in
            guard let path = w.displayPath, w.count > 0, let baseline = w.fileBaseline else { return nil }; return (path,baseline)
        }
        Task { [weak self] in
            let changed = await Task.detached(priority:.utility) {
                items.filter { (try? $0.1.verify(URL(fileURLWithPath:$0.0))) == nil }.map(\.0)
            }.value
            for path in changed { self?.research.setWarning(path:path,message:"原文件在其他软件中发生变化；当前窗口可能仍显示旧内容，请核对书签、页码、锚点和草稿，再重新载入或另存副本") }
        }
    }
}
