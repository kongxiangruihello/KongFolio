import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// One column of a vertical page as the reader proofreads it: the picture of the column next to its recognised text.
struct ProofColumn: Identifiable, Equatable {
    var id: Int
    /// The text as recognised, and as it stands now.
    var original: String
    var text: String
    /// Where the column is (fractions of the page, origin bottom-left).
    var box: CGRect
    var confidence: Float
    /// The pieces the column was recognised in: one per character, or one for the whole column when positions are approximate.
    var pieces: [RecognizedLine]
    var perCharacter: Bool

    var isEdited: Bool { text != original }
    func isDoubtful(below threshold: Float) -> Bool { confidence < threshold }
}

enum ColumnProofreading {
    static let doubtfulThreshold: Float = OCRQuality.lowConfidence

    /// The columns of a vertical page in reading order (right to left), or nil for a page that is not vertical.
    static func columns(_ lines: [RecognizedLine]) -> [ProofColumn]? {
        guard let glyphs = OrderedText.characters(lines) else { return nil }
        var result: [ProofColumn] = []
        var last = -1
        for glyph in glyphs {
            if glyph.column != last {
                result.append(ProofColumn(id: result.count, original: "", text: "", box: glyph.box, confidence: glyph.confidence, pieces: [], perCharacter: !glyph.approximate))
                last = glyph.column
            }
            let at = result.count - 1
            result[at].original += glyph.text
            result[at].text += glyph.text
            result[at].box = result[at].box.union(glyph.box)
            result[at].confidence = min(result[at].confidence, glyph.confidence)
            if glyph.approximate {
                if result[at].pieces.isEmpty { result[at].pieces = [RecognizedLine(text: "", box: glyph.box, confidence: glyph.confidence, approximate: true)] }
                result[at].pieces[0].text += glyph.text
            } else {
                result[at].pieces.append(RecognizedLine(text: glyph.text, box: glyph.box, confidence: glyph.confidence))
            }
        }
        return result
    }

    /// The recognition records after proofreading. A column left alone keeps its records; a column with as many characters as
    /// before keeps each character's position and is marked as sure; a column whose length changed becomes one piece over the
    /// column. A column emptied by the reader is dropped.
    static func lines(from columns: [ProofColumn]) -> [RecognizedLine] {
        var result: [RecognizedLine] = []
        for column in columns {
            guard column.isEdited else { result += column.pieces; continue }
            let text = column.text.filter { !$0.isWhitespace }
            guard !text.isEmpty else { continue }
            if column.perCharacter, column.pieces.count == text.count {
                for (piece, character) in zip(column.pieces, text) {
                    result.append(RecognizedLine(text: String(character), box: piece.box, confidence: 1))
                }
            } else {
                result.append(RecognizedLine(text: text, box: column.box, confidence: 1, approximate: true))
            }
        }
        return result
    }

    /// How many of the page's characters the proofreading changed (edit distance over the whole page's text).
    static func changes(in columns: [ProofColumn]) -> OCRAccuracy.Result {
        OCRAccuracy.compare(reference: columns.map(\.text).joined(), recognized: columns.map(\.original).joined())
    }

    /// The part of a page picture to show for a column: `box` is in fractions with the origin bottom-left; the result is in
    /// the picture's own pixels with the origin top-left, widened a little so neighbouring strokes give context.
    static func cropRect(box: CGRect, imageSize: CGSize, padding: CGFloat = 0.01) -> CGRect {
        let x = max(0, box.minX - padding), right = min(1, box.maxX + padding)
        let bottom = max(0, box.minY - padding), top = min(1, box.maxY + padding)
        return CGRect(x: x * imageSize.width, y: (1 - top) * imageSize.height, width: (right - x) * imageSize.width, height: (top - bottom) * imageSize.height)
    }
}

extension Workspace {
    /// Writes the proofread columns of the page being read back: the page's records (which search and ⌘C use on vertical
    /// pages) and, when the page from before recognition is kept, its text layer.
    @discardableResult func applyProofreading(_ columns: [ProofColumn], page index: Int) -> Bool {
        let lines = ColumnProofreading.lines(from: columns)
        guard !lines.isEmpty, index < document.pageCount else { return false }
        let change = ColumnProofreading.changes(in: columns)
        guard change.edits > 0 || columns.contains(where: \.isEdited) else { return false }
        checkpoint()
        updateMeta(index) { $0.ocrRegions = lines }
        var layerNote = "文字层已同步"
        if let data = meta(index).ocrOriginal, let source = PDFDocument(data: data)?.page(at: 0),
           let replacement = try? DocumentServices.searchablePage(source, lines: lines), let old = document.page(at: index) {
            for annotation in old.annotations { if let copy = annotation.copy() as? PDFAnnotation { replacement.addAnnotation(copy) } }
            document.removePage(at: index)
            document.insert(replacement, at: index)
            edited(pages: [index])
        } else {
            layerNote = "此页没有 OCR 前的原页，只更新了识别记录（搜索与竖排复制用它），页面文字层未改"
            edited(pdfChanged: false)
        }
        status = "校对已应用：改动 \(change.edits) 字（\(String(format: "%.1f", change.errorRate * 100))%），\(layerNote)"
        return true
    }
}
