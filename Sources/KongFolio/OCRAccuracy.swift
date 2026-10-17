import Foundation

/// Measures how far a recognition result is from a corrected text: the character error rate (CER) used for
/// OCR engines — edit distance (insertions, deletions, substitutions) divided by the length of the reference.
/// Whitespace and punctuation are ignored, because the engine does not recognise punctuation in most old books
/// and the reader's corrected text may or may not add it.
enum OCRAccuracy {
    struct Result: Equatable {
        var edits: Int
        var referenceCount: Int
        var recognizedCount: Int
        /// Share of reference characters that are wrong (can exceed 1 when much extra text was recognised).
        var errorRate: Double { referenceCount == 0 ? (recognizedCount == 0 ? 0 : 1) : Double(edits) / Double(referenceCount) }
        var accuracy: Double { max(0, 1 - errorRate) }
    }

    static func normalized(_ text: String) -> [Character] {
        text.filter { character in
            !character.isWhitespace && !character.isPunctuation && !character.isSymbol
        }.map { $0 }
    }

    static func compare(reference: String, recognized: String) -> Result {
        let a = normalized(reference), b = normalized(recognized)
        return Result(edits: distance(a, b), referenceCount: a.count, recognizedCount: b.count)
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The text of a page's recognition records in reading order (vertical pages: columns right to left).
    static func readingText(of lines: [RecognizedLine]) -> String {
        if let columns = OrderedText.verticalColumns(lines) { return columns.joined() }
        return lines.map(\.text).joined()
    }
}

extension Workspace {
    /// Compares the current page's recognition with a corrected text the reader pasted.
    func compareAccuracy() {
        guard let lines = meta(selection).ocrRegions, !lines.isEmpty else {
            accuracyMessage = "当前页没有识别记录，请先做 OCR。"
            return
        }
        let reference = accuracyReference
        guard !OCRAccuracy.normalized(reference).isEmpty else {
            accuracyMessage = "请先粘贴这一页的校对稿。"
            return
        }
        let result = OCRAccuracy.compare(reference: reference, recognized: OCRAccuracy.readingText(of: lines))
        accuracyMessage = String(format: "第 %d 页：字准确率 %.1f%%（编辑距离 %d，校对稿 %d 字，识别 %d 字）",
                                 selection + 1, result.accuracy * 100, result.edits, result.referenceCount, result.recognizedCount)
    }
}
