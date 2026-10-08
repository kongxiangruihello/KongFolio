import AppKit
import PDFKit
import UniformTypeIdentifiers

enum JobOperation { case ocr, compress, split, images, configured, inspectOCR }
struct JobSpec {
    var operation: JobOperation
    var source: Data
    var pages: [Int]
    var destination: URL?
    var revision: UUID
    var exportOptions: ExportOptions? = nil
    var forceOCR = false
    var ocrSources: [Int: Data] = [:]
}
struct JobResult {
    var pdf: Data?
    var text = ""
    var destination: URL?
    var message: String
    var regions: [Int: [RecognizedLine]] = [:]
    var originals: [Int: Data] = [:]
}
enum BackgroundJobs {
    static func run(_ spec: JobSpec, progress: @escaping @Sendable (Double) -> Void) throws -> JobResult {
        try Task.checkCancellation()
        if spec.operation == .configured { return try ExportServices.run(spec, progress: progress) }
        guard let doc = PDFDocument(data: spec.source), !spec.pages.isEmpty, spec.pages.allSatisfy({ (0..<doc.pageCount).contains($0) }) else { throw FolioError(message: "任务页面范围无效。") }
        let output = PDFDocument()
        var regions: [Int: [RecognizedLine]] = [:], originals: [Int: Data] = [:]
        var recognizedCount = 0
        var staging: URL?
        var finalFolder: URL?
        if spec.operation == .split || spec.operation == .images {
            let parent = try spec.destination.unwrap("未选择导出目录")
            let id = UUID().uuidString
            staging = parent.appendingPathComponent(".KongFolio-\(id).partial", isDirectory: true)
            finalFolder = parent.appendingPathComponent("KongFolio-\(id.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: staging!, withIntermediateDirectories: true)
        }
        // This directory is private to this job; no user file is removed on cancellation.
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        for (offset, index) in spec.pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                if spec.forceOCR, let original = spec.ocrSources[index], let source = PDFDocument(data: original), let page = source.page(at: 0)?.copy() as? PDFPage { doc.removePage(at: index); doc.insert(page, at: index) }
                let page = try doc.page(at: index).unwrap("无法读取页面")
                switch spec.operation {
                case .ocr:
                    if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        originals[index] = DocumentServices.subset(doc, indexes: [index]).dataRepresentation()
                        let lines = try DocumentServices.recognize(DocumentServices.render(page))
                        regions[index] = lines; recognizedCount += 1
                        try Task.checkCancellation()
                        if !lines.isEmpty {
                            let replacement = try DocumentServices.searchablePage(page, lines: lines)
                            doc.removePage(at: index); doc.insert(replacement, at: index)
                        }
                    }
                case .inspectOCR:
                    regions[index] = try DocumentServices.recognize(DocumentServices.render(page))
                case .configured: break
                case .compress:
                    let cg = try DocumentServices.render(page, maxDimension: 1400)
                    let rep = NSBitmapImageRep(cgImage: cg)
                    let jpeg = try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.65]).unwrap("压缩页面失败")
                    let image = try NSImage(data: jpeg).unwrap("压缩图片读取失败")
                    let b = page.bounds(for: .cropBox)
                    image.size = abs(page.rotation % 180) == 90 ? CGSize(width: b.height, height: b.width) : b.size
                    output.insert(try PDFPage(image: image).unwrap("压缩 PDF 页面创建失败"), at: output.pageCount)
                case .split:
                    let url = staging!.appendingPathComponent(String(format: "page-%04d.pdf", index + 1))
                    try DocumentServices.subset(doc, indexes: [index]).dataRepresentation().unwrap("拆分失败").write(to: url, options: .atomic)
                case .images:
                    let url = staging!.appendingPathComponent(String(format: "page-%04d.png", index + 1))
                    try DocumentServices.writeImage(DocumentServices.render(page), to: url, type: .png)
                }
            }
            progress(Double(offset + 1) / Double(spec.pages.count))
        }
        try Task.checkCancellation()
        switch spec.operation {
        case .ocr:
            return JobResult(pdf: try doc.dataRepresentation().unwrap("OCR 保存失败"), text: doc.string ?? "", message: "OCR 完成，识别 \(recognizedCount) 页；其余已有文本页已跳过", regions: regions, originals: originals)
        case .inspectOCR: return JobResult(message: "识别区域检查完成，未修改页面文字", regions: regions)
        case .configured: throw FolioError(message: "导出任务未执行")
        case .compress:
            let data = try output.dataRepresentation().unwrap("压缩保存失败")
            try data.write(to: spec.destination.unwrap("没有导出位置"), options: .atomic)
            return JobResult(message: "压缩副本已导出：\(data.count / 1024) KB")
        case .split, .images:
            try FileManager.default.moveItem(at: staging!, to: finalFolder!)
            return JobResult(destination: finalFolder, message: "已导出 \(spec.pages.count) 个文件")
        }
    }
}
extension Workspace {
    func runJob(_ spec: JobSpec) {
        guard !busy else { return }
        busy = true; progress = 0; lastJob = spec
        switch spec.operation { case .ocr: taskLabel = "识别文本"; case .compress: taskLabel = "压缩 PDF"; case .split: taskLabel = "拆分 PDF"; case .images: taskLabel = "导出图片"; case .configured: taskLabel = "按设置导出"; case .inspectOCR: taskLabel = "检查 OCR 区域" }
        status = taskLabel
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try BackgroundJobs.run(spec) { value in Task { @MainActor in self.progress = value } }
        }
        activeJob = worker
        Task {
            defer { busy = false; activeJob = nil }
            do {
                let result = try await worker.value
                if result.pdf != nil || spec.operation == .inspectOCR { checkpoint() }
                ocrOriginals.merge(result.originals) { _, new in new }; ocrRegions.merge(result.regions) { _, new in new }
                if let pdf = result.pdf, let updated = PDFDocument(data: pdf) {
                    document = updated; ReadingServices.applyOutline(outlineEntries, to: document)
                    recognizedText = result.text; changed()
                }
                if spec.operation == .inspectOCR { edited(); showOCRReview = true; reviewSelection = -1 }
                status = result.message; lastJob = nil
                if let destination = result.destination { NSWorkspace.shared.open(destination) }
            } catch is CancellationError { status = "任务已取消；当前文档未改动" }
            catch { self.error = error.localizedDescription; status = "任务失败，可重试" }
        }
    }
    func cancelJob() { activeJob?.cancel(); cancelAuxiliary?(); taskLabel = "正在取消（完成当前页后停止）" }
    func retryJob() {
        guard let job = lastJob else { return }
        guard ![JobOperation.ocr, .inspectOCR].contains(job.operation) || job.revision == revision else { error = "文档已更改，请重新发起 OCR。"; lastJob = nil; return }
        runJob(job)
    }
    func ocr(selectedOnly: Bool = false, force: Bool = false) {
        guard count > 0, !busy, checkDraftsForExport(), let source = try? pdfData() else { return }
        let pages = selectedOnly ? effectivePages : Array(0..<count)
        if force {
            guard pages.allSatisfy({ ocrOriginals[$0] != nil }) else { error = "重新识别仅支持在 0.3 中生成过 OCR 的页面；其他页面请先使用识别区域检查。"; return }
            let alert = NSAlert(); alert.messageText = "重新识别会从 OCR 前的页面重新生成文本层"; alert.informativeText = "这些页面在上次 OCR 后新增的标注会被替换，操作可撤销。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新识别")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        runJob(JobSpec(operation: .ocr, source: source, pages: pages, revision: revision, forceOCR: force, ocrSources: ocrOriginals))
    }
    func inspectOCR() {
        guard !busy, count > 0, let data = try? pdfData() else { return }
        runJob(JobSpec(operation: .inspectOCR, source: data, pages: [selection], revision: revision))
    }
    func compress() { openExport(format: "PDF", raster: true) }
    func exportBatch(split: Bool, selectedOnly: Bool = false) {
        if !split { openExport(format: "PNG", scope: selectedOnly ? "选中页面" : "全部页面"); return }
        guard count > 0, !busy, checkDraftsForExport(), let source = try? pdfData() else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        runJob(JobSpec(operation: split ? .split : .images, source: source, pages: selectedOnly ? effectivePages : Array(0..<count), destination: folder, revision: revision))
    }
}
