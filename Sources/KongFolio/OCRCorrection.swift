import AppKit
import PDFKit

extension Workspace {
    /// Rebuild from the page saved before OCR, so repeated corrections never stack text layers.
    @discardableResult func applyOCRCorrections(_ proposed: [RecognizedLine], page index: Int, expected: [RecognizedLine]? = nil) -> Bool {
        guard !busy, (0..<count).contains(index), let previous = meta(index).ocrRegions,
              previous.count == proposed.count, previous != proposed else { return false }
        guard expected == nil || expected == previous else { error = "识别记录在校正期间已变化，请重新打开校正窗口"; return false }
        guard let data = meta(index).ocrOriginal, let original = PDFDocument(data: data), let source = original.page(at: 0),
              let old = document.page(at: index) else { error = "此页没有保留 OCR 前原页，请先用本应用执行 OCR 后再校正文字层。"; return false }
        do {
            let lines = zip(previous, proposed).map { before, after -> RecognizedLine in
                var result = before
                result.text = after.text
                if before.text != after.text { result.originalText = before.originalText ?? before.text; result.confidence = 1 }
                return result
            }
            var replacement = try withExtendedLifetime(original) { try DocumentServices.searchablePage(source, lines: lines.filter { !$0.text.isEmpty }) }
            var signatureEdit: SignatureEditArchive?
            if let edit = signatureEditArchives[index] {
                let rebased = try SignatureRebase.prepare(edit, on: replacement)
                replacement = rebased.page; signatureEdit = rebased.archive
            }
            for annotation in old.annotations { if let copy = annotation.copy() as? PDFAnnotation { replacement.addAnnotation(copy) } }
            checkpoint()
            document.removePage(at: index); document.insert(replacement, at: index)
            if let signatureEdit { var all = signatureEditArchives; all[index] = signatureEdit; restoreSignatureEdits(all) }
            updateMeta(index) { $0.ocrRegions = lines }
            ReadingServices.applyOutline(outlineEntries, to: document)
            recognizedText = lines.map(\.text).joined(separator: "\n")
            edited(pages: [index]); refreshConfidenceMarks()
            status = "OCR 校正已应用，复制、搜索和导出已更新；⌘Z 可撤销"
            return true
        } catch { self.error = "OCR 校正失败：" + error.localizedDescription; return false }
    }
}
