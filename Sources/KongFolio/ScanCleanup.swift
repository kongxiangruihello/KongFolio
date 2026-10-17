import AppKit
import PDFKit

extension DocumentServices {
    /// The page redrawn as a picture after `values`, at the size the page had (so a scanned book keeps its page size).
    static func cleanedPage(_ page: PDFPage, _ values: ImageAdjustments, maxDimension: CGFloat = 3000) throws -> PDFPage {
        let bounds = page.bounds(for: .cropBox)
        let source = try render(page, maxDimension: maxDimension)
        let result = try adjusted(source, values)
        let pointsPerPixel = max(bounds.width, bounds.height) / CGFloat(max(source.width, source.height))
        let image = NSImage(cgImage: result, size: CGSize(width: CGFloat(result.width) * pointsPerPixel, height: CGFloat(result.height) * pointsPerPixel))
        return try PDFPage(image: image).unwrap("页面生成失败")
    }
}

extension Workspace {
    /// The image-mode settings that make sense for every page: the crop and perspective belong to one page.
    var batchAdjustments: ImageAdjustments {
        var values = adjustments
        values.cropRect = nil
        values.perspective = nil
        return values
    }

    /// Applies the current image settings (brightness, contrast, saturation, sharpness, tilt, scan enhancement,
    /// rotation) to many pages in the background. The pages become pictures, as when one page is applied; the
    /// original pages are not kept in the project, but the whole step can be undone.
    func cleanPages(scope: CropScope) {
        guard count > 0, !busy, checkDraftsForExport(), let data = try? pdfData() else { return }
        let values = batchAdjustments
        guard values != ImageAdjustments() else { error = "请先调整亮度、对比度、扫描增强等参数，再批量应用。"; return }
        let pages = scope == .all ? Array(0..<count) : effectivePages
        let withText = pages.filter { index in document.page(at: index).map { BackgroundJobs.textCharacterCount($0) >= ocrSettings.minimumTextCharacters } ?? false }.count
        let marked = pages.reduce(0) { total, index in total + (document.page(at: index).map { Workspace.visibleAnnotations(on: $0).count } ?? 0) }
        var warnings: [String] = []
        if withText > 0 { warnings.append("\(withText) 页含有可搜索的文字，处理后文字层不再保留（之后可重新 OCR）") }
        if marked > 0 { warnings.append("这些页面上共 \(marked) 个标注会固化进图片") }
        let detail = (warnings.isEmpty ? "" : warnings.joined(separator: "；") + "。") + "页面会转为图片，不保留原始页面；整个操作可撤销。"
        guard confirm("把当前调整应用到 \(pages.count) 页", detail, action: "开始处理") else { return }
        runJob(JobSpec(operation: .cleanup, source: data, pages: pages, revision: revision, cleanup: values))
    }
}
