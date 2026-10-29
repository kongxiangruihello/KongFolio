import AppKit
import PDFKit
import UniformTypeIdentifiers

enum JobOperation { case ocr, compress, split, configured, inspectOCR, chapters, word }

struct JobSpec {
    var operation: JobOperation
    var source: Data
    var pages: [Int]
    var destination: URL?
    var revision: UUID
    var exportOptions: ExportOptions? = nil
    var outputBaseline: FileBaseline? = nil
    var protectedSource: URL? = nil
    /// For an `ocr` job whose `source` holds only some pages of the open document: where each of them belongs.
    var pageMap: [Int] = []
    var forceOCR = false
    var ocrSources: [Int: Data] = [:]
    var ocr = OCRSettings()
    var chapters: [ChapterPart] = []
    var compress = CompressLevel.standard
    var compressKeepMarked = true
    /// Size to reach, in bytes; when set, the level is ignored and stronger settings are tried until the file fits.
    var compressTarget: Int? = nil
    /// Settings and table of contents for a `word` job.
    var word = WordExportOptions()
    var outline: [OutlineEntry] = []
    /// Recognition records by page, for reading vertical pages in the right order.
    var regions: [Int: [RecognizedLine]] = [:]
    /// Later chunks of one OCR run share the first chunk's undo step.
    var continuation = false
}

struct JobResult {
    var pdf: Data?
    var text = ""
    var destination: URL?
    var message: String
    var regions: [Int: [RecognizedLine]] = [:]
    var originals: [Int: Data] = [:]
    /// Pages recognized and pages left alone by an `ocr` job, so a chunked run can add them up.
    var recognized = 0
    var skipped = 0
}

enum BackgroundJobs {
    static func textCharacterCount(_ page: PDFPage) -> Int {
        (page.string ?? "").reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    static func recognize(_ page: PDFPage, settings: OCRSettings) throws -> [RecognizedLine] {
        var image = try DocumentServices.render(page, maxDimension: DocumentServices.ocrPixelDimension(for: page, dpi: settings.dpi))
        if settings.ignoresRedMarks { image = try DocumentServices.withoutRedMarks(image) }
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
            try spec.validateOutput(target)
            let expected = try spec.outputBaseline ?? FileBaseline.capture(target)
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
            try DocumentTaskOutput.write(to: target, expected: expected, protectedSource: spec.protectedSource) { try result.data.write(to: $0) }
            return JobResult(destination: nil, message: result.report.summary)
        }
        if spec.operation == .word {
            let target = try spec.destination.unwrap("没有导出位置")
            try spec.validateOutput(target)
            let expected = try spec.outputBaseline ?? FileBaseline.capture(target)
            var summary = ""
            try DocumentTaskOutput.write(to: target, expected: expected, protectedSource: spec.protectedSource) { staging in
                summary = try WordExport.write(doc, pages: spec.pages, outline: spec.outline, options: spec.word, regions: spec.regions, to: staging, sourceDigest: OCRPageCache.digest(spec.source), progress: progress).summary
            }
            return JobResult(destination: nil, message: summary)
        }
        var regions: [Int: [RecognizedLine]] = [:], originals: [Int: Data] = [:]
        var recognizedCount = 0, skipped = 0
        var staging: URL?
        var finalFolder: URL?
        if spec.operation == .split {
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
                    if spec.forceOCR || spec.ocr.ignoresTextLayer || textCharacterCount(page) < spec.ocr.minimumTextCharacters {
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
                case .configured, .chapters, .compress, .word:
                    break
                case .split:
                    let url = staging!.appendingPathComponent(String(format: "page-%04d.pdf", index + 1))
                    try DocumentServices.subset(doc, indexes: [index]).dataRepresentation().unwrap("拆分失败").write(to: url, options: .atomic)
                }
            }
            progress(Double(offset + 1) / Double(spec.pages.count))
        }
        try Task.checkCancellation()
        switch spec.operation {
        case .ocr:
            let approximate = regions.values.flatMap { $0 }.contains { $0.approximate == true }
            let note = spec.ocr.vertical ? (approximate ? "（竖排模式：部分列未能逐字对位，这些列的高亮位置为整列近似）" : "（竖排模式）") : ""
            return JobResult(pdf: try doc.dataRepresentation().unwrap("OCR 保存失败"), text: doc.string ?? "", message: "OCR 完成，识别 \(recognizedCount) 页，跳过 \(skipped) 个已有文字的页面\(note)", regions: regions, originals: originals, recognized: recognizedCount, skipped: skipped)
        case .inspectOCR:
            return JobResult(message: "识别区域检查完成，未修改页面文字", regions: regions)
        case .configured, .chapters, .compress, .word:
            throw FolioError(message: "导出任务未执行")
        case .split:
            try FileManager.default.moveItem(at: staging!, to: finalFolder!)
            return JobResult(destination: finalFolder, message: "已导出 \(spec.pages.count) 个文件")
        }
    }
}

struct OCRChain {
    var total: Int
    var remaining: [[Int]]
    var done = 0
    var recognized = 0
    var skipped = 0
    var text = ""
}

extension Workspace {
    /// Puts a chunk's results into the open document: only the pages that gained a text layer are swapped, the
    /// rest of the book is not touched or re-saved.
    func applyChunk(_ result: JobResult, _ spec: JobSpec) {
        for (local, data) in result.originals where spec.pageMap.indices.contains(local) { updateMeta(spec.pageMap[local]) { $0.ocrOriginal = data } }
        for (local, lines) in result.regions where spec.pageMap.indices.contains(local) { updateMeta(spec.pageMap[local]) { $0.ocrRegions = lines } }
        var replaced = Set<Int>()
        if let pdf = result.pdf, let done = PDFDocument(data: pdf) {
            for (local, lines) in result.regions where !lines.isEmpty && spec.pageMap.indices.contains(local) {
                let global = spec.pageMap[local]
                guard global < document.pageCount, let page = done.page(at: local)?.copy() as? PDFPage else { continue }
                document.removePage(at: global)
                document.insert(page, at: global)
                replaced.insert(global)
            }
        }
        ReadingServices.applyOutline(outlineEntries, to: document)
        selectedAnnotation = nil
        if replaced.isEmpty { edited(pdfChanged: false) } else { edited(pages: replaced) }
        if showLowConfidence { refreshConfidenceMarks() }
    }

    /// The job for one run of pages: a small PDF holding just those pages, so a long book is not saved again for every chunk.
    func ocrChunkSpec(_ chunk: [Int], like template: JobSpec) -> JobSpec? {
        let subset = DocumentServices.subset(document, indexes: chunk)
        guard subset.pageCount == chunk.count, let source = subset.dataRepresentation() else { return nil }
        var spec = template
        spec.source = source
        spec.pages = Array(0..<chunk.count)
        spec.pageMap = chunk
        spec.revision = revision
        spec.ocrSources = Dictionary(uniqueKeysWithValues: chunk.enumerated().compactMap { offset, global in ocrOriginals[global].map { (offset, $0) } })
        return spec
    }

    func runJob(_ requested: JobSpec) {
        guard !busy else { return }
        var spec = requested
        if [.configured, .compress, .word].contains(spec.operation), let target = spec.destination {
            do {
                spec.protectedSource = historySource
                try spec.validateOutput(target)
                if spec.outputBaseline == nil { spec.outputBaseline = try FileBaseline.capture(target) }
            } catch { self.error = error.localizedDescription; return }
        }
        busy = true
        progress = 0
        if !spec.continuation && spec.operation != .ocr { ocrChain = nil }
        lastJob = spec
        switch spec.operation {
        case .ocr: taskLabel = "识别文本"
        case .compress: taskLabel = "压缩 PDF"
        case .split: taskLabel = "拆分 PDF"
        case .chapters: taskLabel = "按章节拆分"
        case .configured: taskLabel = "按设置导出"
        case .inspectOCR: taskLabel = "检查 OCR 区域"
        case .word: taskLabel = "导出 Word"
        }
        status = taskLabel
        let began = Date()
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try BackgroundJobs.run(spec) { value in Task { @MainActor in self.progress = self.chainProgress(value, pages: spec.pages.count) } }
        }
        activeJob = worker
        Task {
            var chaining = false
            defer { if !chaining { busy = false; activeJob = nil } }
            do {
                let result = try await worker.value
                let ran = Date().timeIntervalSince(began)
                PerfLog.record(taskLabel, name: displayName, pages: spec.pages.count, seconds: ran, note: "识别 \(result.recognized)，跳过 \(result.skipped)")
                if (result.pdf != nil && !spec.continuation) || spec.operation == .inspectOCR { checkpoint() }
                if !spec.pageMap.isEmpty {
                    applyChunk(result, spec)
                } else {
                    for (index, data) in result.originals { updateMeta(index) { $0.ocrOriginal = data } }
                    for (index, lines) in result.regions { updateMeta(index) { $0.ocrRegions = lines } }
                    if let pdf = result.pdf, let updated = PDFDocument(data: pdf) {
                        document = updated
                        ReadingServices.applyOutline(outlineEntries, to: document)
                        recognizedText = result.text
                        changed()
                        if showLowConfidence { refreshConfidenceMarks() }
                    }
                }
                if spec.operation == .inspectOCR {
                    edited(pdfChanged: false)
                    showOCRReview = true
                    reviewSelection = -1
                }
                if spec.operation == .ocr, var chain = ocrChain {
                    chain.recognized += result.recognized
                    chain.skipped += result.skipped
                    chain.done += spec.pages.count
                    chain.text += result.text
                    ocrChain = chain
                    if let next = chain.remaining.first {
                        ocrChain?.remaining.removeFirst()
                        chaining = true
                        busy = false
                        activeJob = nil
                        continueOCR(pages: next, like: spec)
                        return
                    }
                    ocrChain = nil
                    if !spec.pageMap.isEmpty { recognizedText = chain.text }
                    status = "OCR 完成，识别 \(chain.recognized) 页，跳过 \(chain.skipped) 个已有文字的页面" + (spec.ocr.vertical ? "（竖排模式）" : "")
                } else {
                    status = result.message
                }
                lastJob = nil
                if let destination = result.destination { NSWorkspace.shared.open(destination) }
            } catch is CancellationError {
                if let chain = ocrChain, chain.done > 0 {
                    status = "已取消；前 \(chain.done) 页的识别结果已保留，可用“继续识别”接着做"
                } else {
                    status = "任务已取消；当前文档未改动"
                }
                ocrChain = nil
            } catch {
                self.error = error.localizedDescription
                status = ocrChain.map { $0.done > 0 ? "任务失败；前 \($0.done) 页的结果已保留，可重试或“继续识别”" : "任务失败，可重试" } ?? "任务失败，可重试"
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
        guard ![JobOperation.ocr, .inspectOCR].contains(job.operation) || job.revision == revision else {
            error = "文档已更改，请重新发起 OCR。"
            lastJob = nil
            return
        }
        runJob(job)
    }

    /// Pages per background job; each chunk is applied as soon as it finishes, so a cancel keeps the earlier ones.
    nonisolated static let ocrChunkSize = 10

    nonisolated static func chunks(_ pages: [Int], size: Int = ocrChunkSize) -> [[Int]] {
        guard size > 0 else { return [pages] }
        return stride(from: 0, to: pages.count, by: size).map { Array(pages[$0..<min($0 + size, pages.count)]) }
    }

    func chainProgress(_ value: Double, pages: Int) -> Double {
        guard let chain = ocrChain, chain.total > 0 else { return value }
        return (Double(chain.done) + value * Double(pages)) / Double(chain.total)
    }

    func continueOCR(pages: [Int], like previous: JobSpec) {
        guard var spec = ocrChunkSpec(pages, like: previous) else { ocrChain = nil; error = "无法准备下一批页面。"; return }
        spec.continuation = true
        runJob(spec)
    }

    /// `resume` leaves out pages that already carry recognition records, for picking up an interrupted run.
    func ocr(selectedOnly: Bool = false, force: Bool = false, resume: Bool = false) {
        guard count > 0, !busy, checkDraftsForExport() else { return }
        var pages = selectedOnly ? effectivePages : Array(0..<count)
        if resume { pages = pages.filter { !(meta($0).ocrRegions.map { !$0.isEmpty } ?? false) } }
        guard !pages.isEmpty else { status = "所有页面都已识别"; return }
        if force {
            guard pages.allSatisfy({ meta($0).ocrOriginal != nil }) else {
                error = "重新识别仅支持在 0.3 及以后生成过 OCR 的页面；其他页面请先使用识别区域检查。"
                return
            }
            guard confirm("重新识别会从 OCR 前的页面重新生成文本层", "这些页面在上次 OCR 后新增的标注会被替换，操作可撤销。", action: "重新识别") else { return }
        } else {
            // OCR redraws pages with their annotations burned in; say so before it happens.
            let targets = pages.filter { index in ocrSettings.ignoresTextLayer || (document.page(at: index).map { BackgroundJobs.textCharacterCount($0) < ocrSettings.minimumTextCharacters } ?? false) }
            let flattened = targets.reduce(0) { total, index in total + (document.page(at: index).map { Workspace.visibleAnnotations(on: $0).count } ?? 0) }
            if flattened > 0 {
                guard confirm("OCR 会把 \(flattened) 个标注固化到页面中", "固化后的高亮、笔记和手写不能再编辑或移动，也不会出现在摘录列表里。建议先 OCR、再批注。操作可撤销。", action: "继续识别") else { return }
            }
        }
        var parts = Workspace.chunks(pages, size: ocrChunk)
        let first = parts.removeFirst()
        let template = JobSpec(operation: .ocr, source: Data(), pages: first, revision: revision, forceOCR: force, ocr: ocrSettings)
        guard let spec = ocrChunkSpec(first, like: template) else { error = "无法准备要识别的页面。"; return }
        ocrChain = OCRChain(total: pages.count, remaining: parts)
        runJob(spec)
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

    /// Writes the chosen pages as one PDF each into a folder.
    func splitPages(selectedOnly: Bool = false) {
        guard count > 0, !busy, checkDraftsForExport(), let source = try? pdfData() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        runJob(JobSpec(operation: .split, source: source, pages: selectedOnly ? effectivePages : Array(0..<count), destination: folder, revision: revision))
    }
}

extension JobSpec {
    func validateOutput(_ target: URL) throws {
        if let protectedSource, DocumentTaskOutput.sameFile(protectedSource, target) {
            throw FolioError(message: "导出副本请选择与原文件不同的位置，原文件可用保存功能更新。")
        }
    }
}
