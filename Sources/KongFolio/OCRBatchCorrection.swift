import Foundation
import PDFKit

struct OCRRuleHit: Identifiable, Equatable {
    var page: Int
    var line: Int
    var range: NSRange
    var from: String
    var to: String
    var context: String
    var id: String { "\(page):\(line):\(range.location):\(range.length)" }
    var markedContext: String {
        let value = NSMutableString(string: context)
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= value.length else { return context }
        value.replaceCharacters(in: range, with: "【" + from + "】")
        return value as String
    }
}

enum OCRBatchCorrection {
    /// Ranges refer to the original UTF-16 text. Earlier rules win overlapping matches; replacements never cascade.
    static func matches(regions: [Int: [RecognizedLine]], rules: [ReplacementRule], pages: Set<Int>? = nil) -> [OCRRuleHit] {
        var result: [OCRRuleHit] = []
        for page in regions.keys.sorted() where pages == nil || pages!.contains(page) {
            for (index, line) in (regions[page] ?? []).enumerated() {
                let text = line.text as NSString
                var occupied: [NSRange] = []
                for rule in rules where !rule.from.isEmpty && rule.from != rule.to {
                    var location = 0
                    while location < text.length {
                        let range = text.range(of: rule.from, options: [.literal], range: NSRange(location: location, length: text.length - location))
                        guard range.location != NSNotFound else { break }
                        location = NSMaxRange(range)
                        guard !occupied.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                        occupied.append(range)
                        result.append(OCRRuleHit(page: page, line: index, range: range, from: rule.from, to: rule.to, context: line.text))
                    }
                }
            }
        }
        return result.sorted { ($0.page, $0.line, $0.range.location) < ($1.page, $1.line, $1.range.location) }
    }
    static func prepare(_ archive: ProjectArchive, hits: [OCRRuleHit]) throws -> ProjectArchive {
        guard !hits.isEmpty else { return archive }
        let doc = try PDFDocument(data: archive.pdf).unwrap("无法读取文档")
        var result = archive
        for (page, pageHits) in Dictionary(grouping: hits, by: \.page) {
            try Task.checkCancellation()
            guard var lines = archive.ocrRegions?[page], let originalData = archive.ocrOriginals?[page],
                  let original = PDFDocument(data: originalData), let source = original.page(at: 0), let old = doc.page(at: page) else {
                throw FolioError(message: "第 \(page + 1) 页缺少 OCR 前原页，请先重新识别。")
            }
            for (line, changes) in Dictionary(grouping: pageHits, by: \.line) {
                guard lines.indices.contains(line), changes.allSatisfy({ $0.context == lines[line].text }) else { throw FolioError(message: "识别记录已变化，请重新预览") }
                let value = NSMutableString(string: lines[line].text)
                var rightEdge = value.length
                for hit in changes.sorted(by: { $0.range.location > $1.range.location }) {
                    guard hit.range.location >= 0, hit.range.length > 0, NSMaxRange(hit.range) <= rightEdge, value.substring(with: hit.range) == hit.from else { throw FolioError(message: "纠错范围冲突，请重新预览") }
                    rightEdge = hit.range.location; value.replaceCharacters(in: hit.range, with: hit.to)
                }
                lines[line].originalText = lines[line].originalText ?? lines[line].text
                lines[line].text = value as String; lines[line].confidence = 1
            }
            let rebuilt = try withExtendedLifetime(original) { try DocumentServices.searchablePage(source, lines: lines.filter { !$0.text.isEmpty }) }
            let replacement: PDFPage
            if let edit = archive.signatureEdits?[page], !edit.items.isEmpty {
                let updated = try SignatureRebase.prepare(edit, on: rebuilt)
                result.signatureEdits?[page] = updated.archive
                replacement = updated.page
            } else { replacement = rebuilt }
            for annotation in old.annotations { if let copy = annotation.copy() as? PDFAnnotation { replacement.addAnnotation(copy) } }
            doc.removePage(at: page); doc.insert(replacement, at: page)
            result.ocrRegions?[page] = lines
        }
        ReadingServices.applyOutline(archive.reading?.outline ?? [], to: doc)
        result.pdf = try doc.dataRepresentation().unwrap("无法生成校正后的 PDF"); result.dirty = true
        try result.validate(); return result
    }
}

enum SignatureRebase {
    static func prepare(_ edit: SignatureEditArchive, on source: PDFPage) throws -> (page: PDFPage, archive: SignatureEditArchive) {
        let items = edit.items.map { item -> PlacedSignature in
            var value = item
            if !edit.preserved { value.rect = SignatureStamp.uprightRect(item.rect, pageSize: edit.size, rotation: edit.rotation) }
            return value
        }
        let base = PDFDocument(); base.insert(source, at: 0)
        let bytes = try base.dataRepresentation().unwrap("无法保留签名原页")
        let images = try items.map { (image: try SignatureImage.loadData($0.png).unwrap("签名图片失效"), rect: $0.rect) }
        let page = try SignatureStamp.bake(images, onto: source, preserve: true).unwrap("无法保留签名")
        return (page, SignatureEditArchive(base: bytes, preserved: true, size: source.bounds(for: .cropBox).size, rotation: 0, items: items))
    }
}

extension Workspace {
    func applyOCRBatch(_ hits: [OCRRuleHit], expected: UUID) {
        guard !busy, revision == expected, !hits.isEmpty, placingSignature == nil else { error = "文档已变化，请重新预览纠错结果"; return }
        do {
            let before = try snapshot()
            busy = true; taskLabel = "正在应用 OCR 批量纠错"; progress = 0
            Task { [weak self] in
                do {
                    let after = try await Task.detached(priority: .userInitiated) { try OCRBatchCorrection.prepare(before, hits: hits) }.value
                    guard let self else { return }
                    guard self.revision == expected else { self.busy = false; self.error = "文档已变化，未应用纠错"; return }
                    try self.restore(after, keepProjectURL: true)
                    self.pushUndo(.snapshot(before)); self.busy = false; self.changed(); self.refreshConfidenceMarks()
                    self.showOCRBatchCorrection = false
                    self.status = "已纠正 \(hits.count) 处；搜索、复制和导出已更新，⌘Z 可撤销"
                } catch { self?.busy = false; self?.error = "批量纠错失败：" + error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
