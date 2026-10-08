import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ExportOptions: Equatable, Codable {
    var format = "PDF"
    var scope = "全部页面"
    var rasterPDF = false
    var dpi = 150
    var quality = 0.9
    var type: UTType { switch format { case "JPG": return .jpeg; case "TIFF": return .tiff; default: return .png } }
    var suffix: String { format == "JPG" ? "jpg" : format.lowercased() }
}
struct ExportEstimate { var bytes: Int; var sampled: Int; var total: Int; var exact: Bool }
enum ExportServices {
    static func pixels(_ page: PDFPage, dpi: Int) throws -> CGSize {
        guard [72, 150, 300, 600].contains(dpi) else { throw FolioError(message: "不支持的分辨率") }
        let b = page.bounds(for: .cropBox), rotated = abs(page.rotation % 180) == 90
        let width = ceil((rotated ? b.height : b.width) * Double(dpi) / 72)
        let height = ceil((rotated ? b.width : b.height) * Double(dpi) / 72)
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 80_000_000 else { throw FolioError(message: "当前分辨率的单页像素过大，请降低 DPI（单页上限 8000 万像素）。") }
        return CGSize(width: width, height: height)
    }
    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        let size = try pixels(page, dpi: dpi)
        guard let ref = page.pageRef,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FolioError(message: "无法分配页面渲染内存") }
        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)); ctx.drawPDFPage(ref)
        for annotation in page.annotations { annotation.draw(with: .cropBox, in: ctx) }
        return try ctx.makeImage().unwrap("页面渲染失败")
    }
    static func encode(_ cg: CGImage, options: ExportOptions, pdfJPEG: Bool = false) throws -> Data {
        guard options.quality.isFinite, (0.1...1).contains(options.quality) else { throw FolioError(message: "图片质量值无效") }
        let data = NSMutableData(), type = pdfJPEG ? UTType.jpeg : options.type
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw FolioError(message: "编码器不可用") }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: options.quality, kCGImagePropertyDPIWidth: options.dpi, kCGImagePropertyDPIHeight: options.dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FolioError(message: "图片编码失败") }; return data as Data
    }
    static func preservedPDF(_ doc: PDFDocument, pages: [Int]) throws -> Data {
        if pages == Array(0..<doc.pageCount) { return try doc.dataRepresentation().unwrap("PDF 保存失败") }
        let output = DocumentServices.subset(doc, indexes: pages)
        let outlines = ReadingServices.outline(doc).compactMap { entry -> OutlineEntry? in guard let index = pages.firstIndex(of: entry.page) else { return nil }; var copy = entry; copy.page = index; return copy }
        ReadingServices.applyOutline(outlines, to: output)
        return try output.dataRepresentation().unwrap("PDF 保存失败")
    }
    static func estimate(data: Data, pages: [Int], options: ExportOptions) throws -> ExportEstimate {
        guard let doc = PDFDocument(data: data), !pages.isEmpty, pages.allSatisfy({ (0..<doc.pageCount).contains($0) }) else { throw FolioError(message: "没有可估算的页面") }
        if options.format == "PDF", !options.rasterPDF { return ExportEstimate(bytes: try preservedPDF(doc, pages: pages).count, sampled: pages.count, total: pages.count, exact: true) }
        let sample = Array(pages.prefix(3)); var bytes = 0
        for index in sample { try Task.checkCancellation(); bytes += try autoreleasepool { try encode(render(doc.page(at: index)!, dpi: options.dpi), options: options, pdfJPEG: options.format == "PDF").count } }
        return ExportEstimate(bytes: Int(Double(bytes) / Double(sample.count) * Double(pages.count) * (options.format == "PDF" ? 1.03 : 1)), sampled: sample.count, total: pages.count, exact: options.format != "PDF" && sample.count == pages.count)
    }
    static func run(_ spec: JobSpec, progress: @escaping @Sendable (Double) -> Void) throws -> JobResult {
        guard let options = spec.exportOptions, let doc = PDFDocument(data: spec.source), !spec.pages.isEmpty,
              spec.pages.allSatisfy({ (0..<doc.pageCount).contains($0) }), ["PDF", "PNG", "JPG", "TIFF"].contains(options.format) else { throw FolioError(message: "导出设置无效") }
        let target = try spec.destination.unwrap("请选择导出位置")
        try Task.checkCancellation()
        if options.format == "PDF", !options.rasterPDF {
            let data = try preservedPDF(doc, pages: spec.pages); try Task.checkCancellation(); try data.write(to: target, options: .atomic)
            return JobResult(message: "PDF 已导出，保留页面内容与可编辑标注")
        }
        let output = PDFDocument()
        let batch = options.format != "PDF" && spec.pages.count > 1
        let staging = batch ? target.appendingPathComponent(".KongFolio-\(UUID().uuidString).partial", isDirectory: true) : nil
        if let staging { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        for (offset, index) in spec.pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let page = doc.page(at: index)!, cg = try render(page, dpi: options.dpi)
                let data = try encode(cg, options: options, pdfJPEG: options.format == "PDF")
                try Task.checkCancellation()
                if options.format == "PDF" {
                    let image = try NSImage(data: data).unwrap("压缩图像无效")
                    let b = page.bounds(for: .cropBox)
                    image.size = abs(page.rotation % 180) == 90 ? CGSize(width: b.height, height: b.width) : b.size
                    output.insert(try PDFPage(image: image).unwrap("页面生成失败"), at: output.pageCount)
                } else if let staging { try data.write(to: staging.appendingPathComponent(String(format: "page-%04d", index + 1) + "." + options.suffix), options: .atomic) }
                else { try data.write(to: target, options: .atomic) }
            }
            progress(Double(offset + 1) / Double(spec.pages.count))
        }
        if options.format == "PDF" {
            try Task.checkCancellation(); try output.dataRepresentation().unwrap("导出失败").write(to: target, options: .atomic)
        } else if let staging {
            try Task.checkCancellation(); let folder = target.appendingPathComponent("KongFolio-\(UUID().uuidString.prefix(8))")
            try FileManager.default.moveItem(at: staging, to: folder); return JobResult(destination: folder, message: "已导出 \(spec.pages.count) 张 \(options.format)，\(options.dpi) DPI")
        }
        return JobResult(message: "已导出 \(options.format)，\(options.dpi) DPI")
    }
}
extension Workspace {
    var exportPages: [Int] { switch exportOptions.scope { case "当前页面": return count > 0 ? [selection] : []; case "选中页面": return effectivePages; default: return Array(0..<count) } }
    func openExport(format: String = "PDF", scope: String = "全部页面", raster: Bool = false) { exportOptions.format = format; exportOptions.scope = scope; exportOptions.rasterPDF = raster; exportEstimate = nil; showExport = true }
    func invalidateEstimate() { estimateTask?.cancel(); estimateTask = nil; estimating = false; exportEstimate = nil }
    func estimateExport() {
        guard let data = try? pdfData() else { return }; invalidateEstimate(); estimating = true
        let options = exportOptions, pages = exportPages, version = revision
        let task = Task.detached { try ExportServices.estimate(data: data, pages: pages, options: options) }; estimateTask = task
        Task {
            do { let estimate = try await task.value; guard !task.isCancelled, options == exportOptions, version == revision else { return }; exportEstimate = estimate; estimating = false }
            catch is CancellationError {} catch { estimating = false; self.error = error.localizedDescription }
        }
    }
    func configuredExport() {
        guard checkDraftsForExport(), let data = try? pdfData(), !exportPages.isEmpty else { return }
        let options = exportOptions, pages = exportPages
        invalidateEstimate(); showExport = false
        let destination: URL?
        if options.format == "PDF" || pages.count == 1 { destination = saveURL(type: options.format == "PDF" ? .pdf : options.type, suffix: options.suffix) }
        else { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; destination = panel.runModal() == .OK ? panel.url : nil }
        guard let destination else { return }
        runJob(JobSpec(operation: .configured, source: data, pages: pages, destination: destination, revision: revision, exportOptions: options))
    }
}
