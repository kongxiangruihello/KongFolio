import CoreGraphics
import Foundation
import PDFKit

/// Text of a page that was OCR'd in vertical mode, in reading order (columns right to left),
/// with the position of every character. PDFKit extracts such pages column by column from
/// left to right, so search and export use this order instead of `PDFPage.string`.
struct OrderedText {
    var text: String
    /// One entry per UTF-16 unit of `text`, in upright normalized page coordinates; `.null` for column breaks.
    var boxes: [CGRect]
}

enum ReadingOrder {
    static func isVertical(_ lines: [RecognizedLine]) -> Bool { lines.contains { $0.column != nil } }

    static func ordered(_ lines: [RecognizedLine]) -> OrderedText? {
        guard isVertical(lines) else { return nil }
        // Stable sort by column index; within a column the stored order is top to bottom.
        let columnLines = lines.enumerated().filter { $0.element.column != nil }
            .sorted { ($0.element.column!, $0.offset) < ($1.element.column!, $1.offset) }
            .map(\.element)
        var text = ""
        var boxes: [CGRect] = []
        var current: Int?
        for line in columnLines {
            if let current, current != line.column {
                text += "\n"
                boxes.append(.null)
            }
            current = line.column
            text += line.text
            boxes += Array(repeating: line.box, count: line.text.utf16.count)
        }
        return OrderedText(text: text, boxes: boxes)
    }

    static func text(_ lines: [RecognizedLine]) -> String? { ordered(lines)?.text }

    /// Maps a box in upright normalized coordinates (how OCR results are stored) to PDF page space,
    /// taking the page's rotation and crop box into account.
    static func pageRect(_ box: CGRect, on page: PDFPage) -> CGRect {
        let b = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch rotation {
            case 90: return CGPoint(x: b.maxX - v * b.width, y: b.minY + u * b.height)
            case 180: return CGPoint(x: b.maxX - u * b.width, y: b.maxY - v * b.height)
            case 270: return CGPoint(x: b.minX + v * b.width, y: b.maxY - u * b.height)
            default: return CGPoint(x: b.minX + u * b.width, y: b.minY + v * b.height)
            }
        }
        let a = point(box.minX, box.minY), c = point(box.maxX, box.maxY)
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(a.x - c.x), height: abs(a.y - c.y))
    }

    /// A PDFKit selection covering the given character boxes, for highlighting search hits.
    static func selection(for boxes: [CGRect], on page: PDFPage) -> PDFSelection? {
        var result: PDFSelection?
        var seen: [CGRect] = []
        for box in boxes where !box.isNull && !seen.contains(box) {
            seen.append(box)
            let rect = pageRect(box, on: page)
            let inset = min(rect.width, rect.height) * 0.2
            guard let part = page.selection(for: rect.insetBy(dx: inset, dy: inset)) else { continue }
            if let result { result.add(part) } else { result = part }
        }
        return result
    }
}

extension RecognizedLine {
    /// The same line after the page is rotated 90° clockwise (PDFKit's positive rotation).
    func rotatedClockwise() -> RecognizedLine {
        var rotated = self
        rotated.box = CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
        return rotated
    }
}

extension Workspace {
    /// OCR lines of pages that KongFolio recognized in vertical mode, keyed by page index.
    func orderedOCRLines() -> [Int: [RecognizedLine]] {
        var result: [Int: [RecognizedLine]] = [:]
        for (index, meta) in pageMeta.enumerated() where index < count {
            // Only pages whose text layer came from KongFolio's OCR; inspection results alone don't count.
            if meta.ocrOriginal != nil, let lines = meta.ocrRegions, ReadingOrder.isVertical(lines) { result[index] = lines }
        }
        return result
    }

    /// Page text for export: vertical OCR pages in column order, other pages as PDFKit extracts them.
    func pageText(_ index: Int) -> String {
        let ordered = meta(index).ocrOriginal != nil ? meta(index).ocrRegions.flatMap(ReadingOrder.text) : nil
        return ReadingServices.repairIdeographs(ordered ?? document.page(at: index)?.string ?? "")
    }

    func fullText(markdown: Bool) -> String {
        (0..<count).map { index in (markdown ? "## 第 \(index + 1) 页\n\n" : "") + pageText(index) }.joined(separator: "\n\n")
    }
}
