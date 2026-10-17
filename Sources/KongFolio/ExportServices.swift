import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ExportOptions: Equatable, Codable {
    var format = ExportFormat.pdf
    var scope = ExportScope.all
    var pdfMode = PDFExportMode.preserve
    var dpi = 150
    var quality = 0.9
    /// Page numbers, header, footer and watermark; applied to PDF output only.
    var stamp = StampOptions()
    var type: UTType { format.type }
    var suffix: String { format.suffix }
    var rasterPDF: Bool {
        get { format == .pdf && pdfMode == .raster }
        set { pdfMode = newValue ? .raster : .preserve }
    }
    /// True when pages are rendered to pixels (image formats and image-based PDF).
    var rendersPixels: Bool { format != .pdf || pdfMode == .raster }
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
    /// Writes the pages with PDFKit's image options (macOS 13.4+): images are re-encoded as JPEG and
    /// downsampled for screen, while text, vector content, links and the outline are kept.
    static func optimizedPDF(_ doc: PDFDocument, pages: [Int], to url: URL) throws {
        let source = pages == Array(0..<doc.pageCount) ? doc : try PDFDocument(data: preservedPDF(doc, pages: pages)).unwrap("PDF 生成失败")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard source.write(to: url, withOptions: options) else { throw FolioError(message: "压缩 PDF 写入失败") }
    }

    /// Writes through a temporary file in the destination folder so a failed or cancelled export never leaves half a file.
    static func writeOptimized(_ doc: PDFDocument, pages: [Int], to target: URL) throws -> Int {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try optimizedPDF(doc, pages: pages, to: temporary)
        try Task.checkCancellation()
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: target) }
        return size
    }

    static func estimate(data: Data, pages: [Int], options: ExportOptions) throws -> ExportEstimate {
        guard let doc = PDFDocument(data: data), !pages.isEmpty, pages.allSatisfy({ (0..<doc.pageCount).contains($0) }) else { throw FolioError(message: "没有可估算的页面") }
        if options.format == .pdf, options.stamp.isActive {
            let stamped = try Stamping.apply(options.stamp, to: doc, pages: pages)
            var plain = options; plain.stamp = StampOptions()
            return try estimate(data: try stamped.dataRepresentation().unwrap("带页码的 PDF 生成失败"), pages: Array(0..<stamped.pageCount), options: plain)
        }
        if options.format == .pdf, options.pdfMode == .preserve { return ExportEstimate(bytes: try preservedPDF(doc, pages: pages).count, sampled: pages.count, total: pages.count, exact: true) }
        if options.format == .pdf, options.pdfMode == .optimized {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-estimate-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try optimizedPDF(doc, pages: pages, to: temporary)
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
            return ExportEstimate(bytes: size, sampled: pages.count, total: pages.count, exact: true)
        }
        let sample = Array(pages.prefix(3)); var bytes = 0
        for index in sample { try Task.checkCancellation(); bytes += try autoreleasepool { try encode(render(doc.page(at: index).unwrap("页面读取失败"), dpi: options.dpi), options: options, pdfJPEG: options.format == .pdf).count } }
        return ExportEstimate(bytes: Int(Double(bytes) / Double(sample.count) * Double(pages.count) * (options.format == .pdf ? 1.03 : 1)), sampled: sample.count, total: pages.count, exact: options.format != .pdf && sample.count == pages.count)
    }
    static func run(_ spec: JobSpec, progress: @escaping @Sendable (Double) -> Void) throws -> JobResult {
        guard let options = spec.exportOptions, let doc = PDFDocument(data: spec.source), !spec.pages.isEmpty,
              spec.pages.allSatisfy({ (0..<doc.pageCount).contains($0) }) else { throw FolioError(message: "导出设置无效") }
        let target = try spec.destination.unwrap("请选择导出位置")
        try Task.checkCancellation()
        if options.format == .pdf, options.stamp.isActive {
            // Draw the stamps first, then export the stamped pages like any other document.
            let stamped = try Stamping.apply(options.stamp, to: doc, pages: spec.pages)
            var plain = options; plain.stamp = StampOptions()
            var next = spec
            next.source = try stamped.dataRepresentation().unwrap("带页码的 PDF 生成失败")
            next.pages = Array(0..<stamped.pageCount)
            next.exportOptions = plain
            var result = try run(next, progress: progress)
            result.message += "（已添加页码/页眉页脚/水印；标注已固化，链接不再可点）"
            return result
        }
        if options.format == .pdf, options.pdfMode == .preserve {
            let data = try preservedPDF(doc, pages: spec.pages); try Task.checkCancellation(); try data.write(to: target, options: .atomic)
            return JobResult(message: "PDF 已导出，保留页面内容与可编辑标注")
        }
        if options.format == .pdf, options.pdfMode == .optimized {
            let before = spec.pages == Array(0..<doc.pageCount) ? spec.source.count : try preservedPDF(doc, pages: spec.pages).count
            let after = try writeOptimized(doc, pages: spec.pages, to: target)
            progress(1)
            let sizes = "\(ByteCountFormatter.string(fromByteCount: Int64(before), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(after), countStyle: .file))"
            return JobResult(message: after < before ? "已压缩并保留文字：\(sizes)" : "已导出，但此文件没有变小（\(sizes)）；可改用图片型 PDF")
        }
        let output = PDFDocument()
        let batch = options.format != .pdf && spec.pages.count > 1
        let staging = batch ? target.appendingPathComponent(".KongFolio-\(UUID().uuidString).partial", isDirectory: true) : nil
        if let staging { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        for (offset, index) in spec.pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let page = try doc.page(at: index).unwrap("页面读取失败"), cg = try render(page, dpi: options.dpi)
                let data = try encode(cg, options: options, pdfJPEG: options.format == .pdf)
                try Task.checkCancellation()
                if options.format == .pdf {
                    let image = try NSImage(data: data).unwrap("压缩图像无效")
                    let b = page.bounds(for: .cropBox)
                    image.size = abs(page.rotation % 180) == 90 ? CGSize(width: b.height, height: b.width) : b.size
                    output.insert(try PDFPage(image: image).unwrap("页面生成失败"), at: output.pageCount)
                } else if let staging { try data.write(to: staging.appendingPathComponent(String(format: "page-%04d", index + 1) + "." + options.suffix), options: .atomic) }
                else { try data.write(to: target, options: .atomic) }
            }
            progress(Double(offset + 1) / Double(spec.pages.count))
        }
        if options.format == .pdf {
            try Task.checkCancellation(); try output.dataRepresentation().unwrap("导出失败").write(to: target, options: .atomic)
        } else if let staging {
            try Task.checkCancellation(); let folder = target.appendingPathComponent("KongFolio-\(UUID().uuidString.prefix(8))")
            try FileManager.default.moveItem(at: staging, to: folder); return JobResult(destination: folder, message: "已导出 \(spec.pages.count) 张 \(options.format)，\(options.dpi) DPI")
        }
        return JobResult(message: "已导出 \(options.format)，\(options.dpi) DPI")
    }
}
extension Workspace {
    var exportPages: [Int] {
        switch exportOptions.scope {
        case .current: return count > 0 ? [selection] : []
        case .selected: return effectivePages
        case .all: return Array(0..<count)
        }
    }
    func openExport(format: ExportFormat = .pdf, scope: ExportScope = .all, pdfMode: PDFExportMode = .preserve) {
        exportOptions.format = format
        exportOptions.scope = scope
        exportOptions.pdfMode = pdfMode
        exportEstimate = nil
        showExport = true
    }
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
        if options.format == .pdf || pages.count == 1 { destination = saveURL(type: options.type, suffix: options.suffix) }
        else { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; destination = panel.runModal() == .OK ? panel.url : nil }
        guard let destination else { return }
        runJob(JobSpec(operation: .configured, source: data, pages: pages, destination: destination, revision: revision, exportOptions: options))
    }
}
