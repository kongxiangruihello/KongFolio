import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Reading order for vertical (竖排) pages. PDFKit reads a page's text layer left to right, so the columns of a
/// vertical page come out in the wrong order; the OCR regions stored with the page keep the order they were
/// recognised in (columns from right to left, characters from top to bottom).
enum OrderedText {
    /// A page counts as vertical when most of its recognised pieces are single characters or whole columns.
    static func isVertical(_ lines: [RecognizedLine]) -> Bool {
        guard !lines.isEmpty else { return false }
        let singles = lines.filter { $0.text.count == 1 || $0.approximate == true }.count
        return singles * 100 >= lines.count * 60
    }

    /// One character of a vertical page in reading order, with where it is (fractions of the page, origin bottom-left)
    /// and which column of the page it is in. `approximate` characters share the box of their whole column.
    struct Glyph: Equatable {
        var text: String
        var box: CGRect
        var column: Int
        var approximate: Bool
        var confidence: Float = 1
    }

    /// The characters of a vertical page in reading order, or nil when the regions are not those of a vertical page.
    static func characters(_ lines: [RecognizedLine]) -> [Glyph]? {
        guard isVertical(lines) else { return nil }
        var result: [Glyph] = []
        var column = -1
        var currentX: CGFloat?
        for line in lines {
            let text = line.text.filter { !$0.isWhitespace }
            guard !text.isEmpty else { continue }
            if line.approximate == true || line.text.count != 1 {
                column += 1
                currentX = nil
                for character in text { result.append(Glyph(text: String(character), box: line.box, column: column, approximate: true, confidence: line.confidence)) }
            } else {
                if column < 0 || currentX == nil || abs(line.box.minX - (currentX ?? 0)) >= max(line.box.width, 0.001) * 0.5 {
                    column += 1
                    currentX = line.box.minX
                }
                result.append(Glyph(text: text, box: line.box, column: column, approximate: false, confidence: line.confidence))
            }
        }
        return result
    }

    /// The text of each column in reading order, or nil when the regions are not those of a vertical page.
    static func verticalColumns(_ lines: [RecognizedLine]) -> [String]? {
        guard let characters = characters(lines) else { return nil }
        var columns: [String] = []
        var last = -1
        for character in characters {
            if character.column != last { columns.append(""); last = character.column }
            columns[columns.count - 1] += character.text
        }
        return columns
    }

    /// The text of the characters `isIncluded` accepts, a line per column (what copying a selection should give).
    static func text(of characters: [Glyph], including isIncluded: (Glyph) -> Bool) -> String {
        var lines: [String] = []
        var last = -1
        for character in characters where isIncluded(character) {
            if character.column != last { lines.append(""); last = character.column }
            lines[lines.count - 1] += character.text
        }
        return lines.joined(separator: "\n")
    }

    /// One box (fractions of the page) for every column whose recognition confidence is below `threshold`.
    /// The recognition reports a confidence for a whole column piece, not for single characters.
    static func doubtfulColumns(_ glyphs: [Glyph], threshold: Float) -> [CGRect] {
        var boxes: [Int: CGRect] = [:]
        var lowest: [Int: Float] = [:]
        for glyph in glyphs {
            boxes[glyph.column] = boxes[glyph.column].map { $0.union(glyph.box) } ?? glyph.box
            lowest[glyph.column] = min(lowest[glyph.column] ?? 1, glyph.confidence)
        }
        return boxes.keys.sorted().filter { (lowest[$0] ?? 1) < threshold }.compactMap { boxes[$0] }
    }

    /// Fractions of the page as it is shown (Vision's boxes) → a rectangle in page coordinates.
    static func pageRect(forFraction box: CGRect, cropBox: CGRect, rotation: Int) -> CGRect {
        let quarterTurn = abs(rotation % 180) == 90
        let width = quarterTurn ? cropBox.height : cropBox.width, height = quarterTurn ? cropBox.width : cropBox.height
        let shown = CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
        return SignatureStamp.originalRect(shown, pageSize: cropBox.size, rotation: rotation).offsetBy(dx: cropBox.minX, dy: cropBox.minY)
    }

    /// A rectangle in page coordinates → fractions of the page as it is shown.
    static func fraction(ofPageRect rect: CGRect, cropBox: CGRect, rotation: Int) -> CGRect {
        let quarterTurn = abs(rotation % 180) == 90
        let width = quarterTurn ? cropBox.height : cropBox.width, height = quarterTurn ? cropBox.width : cropBox.height
        guard width > 0, height > 0 else { return .zero }
        let shown = SignatureStamp.uprightRect(rect.offsetBy(dx: -cropBox.minX, dy: -cropBox.minY), pageSize: cropBox.size, rotation: rotation)
        return CGRect(x: shown.minX / width, y: shown.minY / height, width: shown.width / width, height: shown.height / height)
    }

    /// Paragraphs of a page for an export. Vertical pages use the stored order (one paragraph per column when
    /// `keepColumns`, otherwise one paragraph for the page); other pages use the text layer.
    static func paragraphs(regions: [RecognizedLine]?, pageText: String, mergeLines: Bool, keepColumns: Bool) -> [String] {
        if let regions, let columns = verticalColumns(regions) {
            let repaired = columns.map { ReadingServices.repairIdeographs($0) }
            return keepColumns ? repaired : (repaired.isEmpty ? [] : [repaired.joined()])
        }
        return WordExport.paragraphs(from: ReadingServices.repairIdeographs(pageText), merge: mergeLines)
    }
}

/// What looks doubtful about the recognition of one page.
struct OCRPageQuality: Identifiable, Equatable {
    var id: Int { page }
    var page: Int
    var characters: Int
    var reasons: [String]
}

enum OCRQuality {
    static let lowConfidence: Float = 0.5
    static let fewCharacters = 12

    static func assess(page: Int, lines: [RecognizedLine]) -> OCRPageQuality {
        let characters = lines.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
        var reasons: [String] = []
        if characters == 0 {
            reasons.append("没有识别出文字")
        } else {
            if characters < fewCharacters { reasons.append("识别出的字很少（\(characters) 字）") }
            let approximate = lines.filter { $0.approximate == true }.count
            if approximate > 0 { reasons.append("\(approximate) 列未能逐字对位") }
            if let lowest = lines.map(\.confidence).min(), lowest < lowConfidence { reasons.append("最低置信度 \(Int((lowest * 100).rounded()))%") }
        }
        return OCRPageQuality(page: page, characters: characters, reasons: reasons)
    }
}

extension Workspace {
    /// Pages that were recognised in this project and look doubtful. `checked` is how many pages had a record.
    func ocrQualityReport() -> (checked: Int, doubtful: [OCRPageQuality]) {
        var checked = 0
        var doubtful: [OCRPageQuality] = []
        for index in 0..<count {
            guard let lines = meta(index).ocrRegions else { continue }
            checked += 1
            let result = OCRQuality.assess(page: index, lines: lines)
            if !result.reasons.isEmpty { doubtful.append(result) }
        }
        return (checked, doubtful)
    }

    /// Marks, in yellow, the columns of recognised pages whose confidence is low. Marks stay until the option is
    /// switched off; switch it off and on again after recognising more pages.
    func refreshConfidenceMarks() {
        guard let view = pdfView else { return }
        guard showLowConfidence else { view.highlightedSelections = nil; return }
        var marks: [PDFSelection] = []
        for index in 0..<count where marks.count < 600 {
            guard let page = document.page(at: index), let glyphs = OrderedText.characters(meta(index).ocrRegions ?? []) else { continue }
            let crop = page.bounds(for: .cropBox)
            for box in OrderedText.doubtfulColumns(glyphs, threshold: OCRQuality.lowConfidence) {
                guard let mark = page.selection(for: OrderedText.pageRect(forFraction: box, cropBox: crop, rotation: page.rotation)) else { continue }
                mark.color = NSColor.systemYellow.withAlphaComponent(0.5)
                marks.append(mark)
            }
        }
        view.highlightedSelections = marks.isEmpty ? nil : marks
        status = marks.isEmpty ? "没有低置信度的列" : "已标出 \(marks.count) 列低置信度的文字（黄色）"
    }

    func openOCRQuality() {
        guard count > 0 else { return }
        let report = ocrQualityReport()
        ocrChecked = report.checked
        ocrDoubtful = report.doubtful
        showOCRQuality = true
    }

    /// Selects the doubtful pages that can be recognised again and starts the recognition.
    func recognizeDoubtfulAgain() {
        let pages = ocrDoubtful.map(\.page).filter { meta($0).ocrOriginal != nil }
        guard !pages.isEmpty else { error = "这些页面没有 OCR 前的原页保存，无法直接重新识别。请选中它们后用“OCR 当前选中页”。"; return }
        selectedPages = Set(pages)
        showOCRQuality = false
        ocr(selectedOnly: true, force: true)
    }
}
