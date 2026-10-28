import AppKit
import PDFKit
import UniformTypeIdentifiers

extension Workspace {
    func openWordExport() {
        guard count > 0 else { return }
        showWordExport = true
    }

    func startWordExport(reviewed: Bool = false) {
        if !reviewed { do { try reviewExport(.word) { [weak self] in self?.startWordExport(reviewed:true) } } catch { self.error=error.localizedDescription };return }
        guard count > 0, !busy, checkDraftsForExport(), let data = try? pdfData() else { return }
        if wordOptions.content != .imagesOnly {
            do { try validateWordDraft() } catch { self.error = error.localizedDescription; return }
        }
        let exportOptionsWithTables: WordExportOptions
        do { exportOptionsWithTables = try wordOptionsWithTables() } catch { self.error = error.localizedDescription; showWordExport = true; return }
        let pages = wordScope == .all ? Array(0..<count) : effectivePages
        if wordOptions.content != .imagesOnly {
            let hasTables = exportOptionsWithTables.tables?.contains(where: { table in table.regions.contains(where: { pages.contains($0.page) }) }) == true
            let hasText = hasTables || pages.contains { index in document.page(at: index).map { BackgroundJobs.textCharacterCount($0) > 0 } ?? false }
            if !hasText {
                if wordOptions.content == .textOnly { error = "这些页面没有文字，请先运行 OCR。"; return }
                guard confirm("这些页面没有文字层", "只会导出页面图片。需要文字的话，请先运行 OCR 再导出。", action: "只导出图片") else { return }
            }
        }
        showWordExport = false
        var exportOptions = exportOptionsWithTables
        exportOptions.replacements = applyReplacements ? ReplacementRules.parse(replacementText) : []
        guard let destination = saveURL(type: UTType(filenameExtension: "docx") ?? .data, suffix: "docx") else { return }
        do {
            guard let queue = store?.documentTasks else { throw FolioError(message: "后台任务不可用") }
            var spec = PersistentDocumentTask(kind: .word, destination: destination, expected: try FileBaseline.capture(destination), sourceBaseline: fileBaseline)
            spec.pages = pages; spec.word = exportOptions; spec.outline = outlineEntries
            spec.regions = Dictionary(uniqueKeysWithValues: pages.compactMap { index in meta(index).ocrRegions.map { (index, $0) } })
            try queue.startPersistent("导出 Word · \(displayName)", source: data, spec: spec)
            status = "Word 已加入后台任务，可继续阅读"
        } catch { self.error = error.localizedDescription }

    }
}
