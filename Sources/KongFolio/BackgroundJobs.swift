import AppKit
import PDFKit
import UniformTypeIdentifiers

enum JobOperation { case ocr, compress, split, images, configured, inspectOCR, chapters, cleanup }

struct JobSpec {
    var operation: JobOperation
    var source: Data
    var pages: [Int]
    var destination: URL?
    var revision: UUID
    var exportOptions: ExportOptions? = nil
    var forceOCR = false
    var ocrSources: [Int: Data] = [:]
    var ocr = OCRSettings()
    var chapters: [ChapterPart] = []
    var compress = CompressLevel.standard
    var compressKeepMarked = true
    /// Size to reach, in bytes; when set, the level is ignored and stronger settings are tried until the file fits.
    var compressTarget: Int? = nil
    /// Image settings applied to every page of a `cleanup` job.
    var cleanup = ImageAdjustments()
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
    static func textCharacterCount(_ page: PDFPage) -> Int {
        (page.string ?? "").reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    static func recognize(_ page: PDFPage, settings: OCRSettings) throws -> [RecognizedLine] {
        let image = try DocumentServices.render(page, maxDimension: DocumentServices.ocrPixelDimension(for: page, dpi: settings.dpi))
        return settings.vertical
            ? try DocumentServices.recognizeVertical(image, languages: settings.languages)
            : try DocumentServices.recognize(image, languages: settings.languages)
    }

    static func run(_ spec: JobSpec, progress: @escaping @Sendable (Double) -> Void) throws -> JobResult {
        try Task.checkCancellation()
        if spec.operation == .configured { return try ExportServices.run(spec, progress: progress) }
        guard let doc = PDFDocument(data: spec.source), !spec.pages.isEmpty, spec.pages.allSatisfy({ (0..<doc.pageCount).contains($0) }) else { throw FolioError(message: "任务页面范围无效。") }
        if spec.operation == .chapters { return try splitChapters(spec, doc: doc, progress: progress) }
        if spec.operation == .compress {
            let target = try spec.destination.unwrap("没有导出位置")
            let result: (data: Data, report: CompressReport)
            if let size = spec.compressTarget, spec.source.count > size {
                result = try PDFCompressor.compress(source: spec.source, targetBytes: size, keepMarked: spec.compressKeepMarked, progress: progress)
            } else if let size = spec.compressTarget {
                var report = CompressReport(before: spec.source.count, after: spec.source.count, rebuilt: 0, kept: doc.pageCount)
                report.target = size
                result = (Data(), report)
            } else {
                result = try PDFCompressor.compress(doc, level: spec.compress, original: spec.source.count, keepMarked: spec.compressKeepMarked, progress: progress)
            }
            try Task.checkCancellation()
            // A file that did not get smaller is not written: the original is the better copy.
            guard result.report.smaller else { return JobResult(message: result.report.summary) }
            try result.data.write(to: target, options: .atomic)
            return JobResult(destination: nil, message: result.report.summary)
        }
        var regions: [Int: [RecognizedLine]] = [:], originals: [Int: Data] = [:]
        var recognizedCount = 0, skipped = 0
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
                if spec.forceOCR, let original = spec.ocrSources[index], let source = PDFDocument(data: original), let page = source.page(at: 0)?.copy() as? PDFPage {
                    doc.removePage(at: index)
                    doc.insert(page, at: index)
                }
                let page = try doc.page(at: index).unwrap("无法读取页面")
                switch spec.operation {
                case .ocr:
                    // A stray header or scanner stamp no longer makes a scanned page count as "already has text".
                    if spec.forceOCR || textCharacterCount(page) < spec.ocr.minimumTextCharacters {
                        originals[index] = DocumentServices.subset(doc, indexes: [index]).dataRepresentation()
                        let lines = try recognize(page, settings: spec.ocr)
                        regions[index] = lines
                        recognizedCount += 1
                        try Task.checkCancellation()
                        if !lines.isEmpty {
                            let replacement = try DocumentServices.searchablePage(page, lines: lines)
                            doc.removePage(at: index)
                            doc.insert(replacement, at: index)
                        }
                    } else {
                        skipped += 1
                    }
                case .inspectOCR:
                    regions[index] = try recognize(page, settings: spec.ocr)
                case .cleanup:
                    let replacement = try DocumentServices.cleanedPage(page, spec.cleanup)
                    doc.removePage(at: index)
                    doc.insert(replacement, at: index)
                case .configured, .chapters, .compress:
                    break
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
            let approximate = regions.values.flatMap { $0 }.contains { $0.approximate == true }
            let note = spec.ocr.vertical ? (approximate ? "（竖排模式：部分列未能逐字对位，这些列的高亮位置为整列近似）" : "（竖排模式）") : ""
            return JobResult(pdf: try doc.dataRepresentation().unwrap("OCR 保存失败"), text: doc.string ?? "", message: "OCR 完成，识别 \(recognizedCount) 页，跳过 \(skipped) 个已有文字的页面\(note)", regions: regions, originals: originals)
        case .inspectOCR:
            return JobResult(message: "识别区域检查完成，未修改页面文字", regions: regions)
        case .cleanup:
            return JobResult(pdf: try doc.dataRepresentation().unwrap("保存失败"), text: doc.string ?? "", message: "已处理 \(spec.pages.count) 页（可撤销）")
        case .configured, .chapters, .compress:
            throw FolioError(message: "导出任务未执行")
        case .split, .images:
            try FileManager.default.moveItem(at: staging!, to: finalFolder!)
            return JobResult(destination: finalFolder, message: "已导出 \(spec.pages.count) 个文件")
        }
    }
}

extension Workspace {
    func runJob(_ spec: JobSpec) {
        guard !busy else { return }
        busy = true
        progress = 0
        lastJob = spec
        switch spec.operation {
        case .ocr: taskLabel = "识别文本"
        case .compress: taskLabel = "压缩 PDF"
        case .split: taskLabel = "拆分 PDF"
        case .chapters: taskLabel = "按章节拆分"
        case .images: taskLabel = "导出图片"
        case .configured: taskLabel = "按设置导出"
        case .inspectOCR: taskLabel = "检查 OCR 区域"
        case .cleanup: taskLabel = "批量处理页面"
        }
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
                for (index, data) in result.originals { updateMeta(index) { $0.ocrOriginal = data } }
                for (index, lines) in result.regions { updateMeta(index) { $0.ocrRegions = lines } }
                if spec.operation == .cleanup { for index in spec.pages { updateMeta(index) { $0 = PageMeta() } } }
                if let pdf = result.pdf, let updated = PDFDocument(data: pdf) {
                    document = updated
                    ReadingServices.applyOutline(outlineEntries, to: document)
                    recognizedText = result.text
                    changed()
                }
                if spec.operation == .inspectOCR {
                    edited(pdfChanged: false)
                    showOCRReview = true
                    reviewSelection = -1
                }
                status = result.message
                lastJob = nil
                if let destination = result.destination { NSWorkspace.shared.open(destination) }
            } catch is CancellationError {
                status = "任务已取消；当前文档未改动"
            } catch {
                self.error = error.localizedDescription
                status = "任务失败，可重试"
            }
        }
    }

    func cancelJob() {
        activeJob?.cancel()
        cancelAuxiliary?()
        taskLabel = "正在取消（完成当前页后停止）"
    }

    func retryJob() {
        guard let job = lastJob else { return }
        guard ![JobOperation.ocr, .inspectOCR, .cleanup].contains(job.operation) || job.revision == revision else {
            error = "文档已更改，请重新发起 OCR。"
            lastJob = nil
            return
        }
        runJob(job)
    }

    func ocr(selectedOnly: Bool = false, force: Bool = false) {
        guard count > 0, !busy, checkDraftsForExport(), let source = try? pdfData() else { return }
        let pages = selectedOnly ? effectivePages : Array(0..<count)
        if force {
            guard pages.allSatisfy({ meta($0).ocrOriginal != nil }) else {
                error = "重新识别仅支持在 0.3 及以后生成过 OCR 的页面；其他页面请先使用识别区域检查。"
                return
            }
            guard confirm("重新识别会从 OCR 前的页面重新生成文本层", "这些页面在上次 OCR 后新增的标注会被替换，操作可撤销。", action: "重新识别") else { return }
        } else {
            // OCR redraws pages with their annotations burned in; say so before it happens.
            let targets = pages.filter { index in document.page(at: index).map { BackgroundJobs.textCharacterCount($0) < ocrSettings.minimumTextCharacters } ?? false }
            let flattened = targets.reduce(0) { total, index in total + (document.page(at: index).map { Workspace.visibleAnnotations(on: $0).count } ?? 0) }
            if flattened > 0 {
                guard confirm("OCR 会把 \(flattened) 个标注固化到页面中", "固化后的高亮、笔记和手写不能再编辑或移动，也不会出现在摘录列表里。建议先 OCR、再批注。操作可撤销。", action: "继续识别") else { return }
            }
        }
        runJob(JobSpec(operation: .ocr, source: source, pages: pages, revision: revision, forceOCR: force, ocrSources: ocrOriginals, ocr: ocrSettings))
    }

    func inspectOCR() {
        guard !busy, count > 0, let data = try? pdfData() else { return }
        runJob(JobSpec(operation: .inspectOCR, source: data, pages: [selection], revision: revision, ocr: ocrSettings))
    }

    /// Compress now keeps text: PDFKit re-encodes embedded images instead of rasterizing every page.
    func compress() {
        guard count > 0 else { return }
        compressScan = nil
        showCompress = true
        guard let data = try? pdfData() else { return }
        Task {
            let result = await Task.detached { () -> (pictureHeavy: Int, marked: Int)? in
                PDFDocument(data: data).map { PDFCompressor.scan($0) }
            }.value
            compressScan = result
        }
    }

    /// Writes a smaller copy next to wherever the reader chooses; the open document is not changed.
    func startCompress() {
        guard count > 0, !busy, checkDraftsForExport(), let data = try? pdfData() else { return }
        showCompress = false
        guard let destination = saveURL(type: .pdf, suffix: "pdf", name: title + "-compressed") else { return }
        runJob(JobSpec(operation: .compress, source: data, pages: Array(0..<count), destination: destination, revision: revision, compress: compressLevel, compressKeepMarked: compressKeepMarked,
                         compressTarget: compressUseTarget ? Int(max(compressTargetMB, 0.1) * 1_000_000) : nil))
    }

    func exportBatch(split: Bool, selectedOnly: Bool = false) {
        if !split { openExport(format: .png, scope: selectedOnly ? .selected : .all); return }
        guard count > 0, !busy, checkDraftsForExport(), let source = try? pdfData() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        runJob(JobSpec(operation: split ? .split : .images, source: source, pages: selectedOnly ? effectivePages : Array(0..<count), destination: folder, revision: revision))
    }
}
