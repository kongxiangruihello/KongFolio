import CoreGraphics
import Foundation

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

    /// The text of each column in reading order, or nil when the regions are not those of a vertical page.
    static func verticalColumns(_ lines: [RecognizedLine]) -> [String]? {
        guard isVertical(lines) else { return nil }
        var columns: [String] = []
        var currentX: CGFloat?
        for line in lines {
            let text = line.text.filter { !$0.isWhitespace }
            guard !text.isEmpty else { continue }
            if line.approximate == true || line.text.count != 1 {
                columns.append(text)
                currentX = nil
            } else if let x = currentX, abs(line.box.minX - x) < max(line.box.width, 0.001) * 0.5, !columns.isEmpty {
                columns[columns.count - 1] += text
            } else {
                columns.append(text)
                currentX = line.box.minX
            }
        }
        return columns
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
