import AppKit
import PDFKit
import Vision

/// All geometry uses fractions of the visible, rotated page, with a top-left origin.
struct TablePiece {
    var text: String
    var box: CGRect
}
struct ExtractedTable {
    var rows: [[String]]
    var columns: Int { rows.first?.count ?? 0 }
    var markdown: String {
        func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "<br>") }
        guard let first = rows.first else { return "" }
        func line(_ row: [String]) -> String { "| " + row.map(escaped).joined(separator: " | ") + " |" }
        return ([line(first), line(Array(repeating: "---", count: columns))] + rows.dropFirst().map(line)).joined(separator: "\n") + "\n"
    }
    var csv: String { "\u{FEFF}" + rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n" }
    func writeWord(to destination: URL) throws {
        var document = try RichTextDocument("", format: .plain)
        document.blocks = [.table(rows.enumerated().map { i, row in row.map { RichTextDocument.styled($0, options: document.options, markdown: false, bold: i == 0) } })]
        try RichTextWord.write(document, to: destination)
    }
}

enum TableExtraction {
    /// Per-character Vision geometry keeps a whole recognized row from landing in one cell.
    static func recognize(_ image: CGImage, languages: [String]) throws -> [TablePiece] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let supported = Set(DocumentServices.supportedOCRLanguages)
        let chosen = languages.filter { supported.isEmpty || supported.contains($0) }
        if !chosen.isEmpty { request.recognitionLanguages = chosen }
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        var pieces: [TablePiece] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            var offset = candidate.string.startIndex
            while offset < candidate.string.endIndex, pieces.count < 100_000 {
                let next = candidate.string.index(after: offset), text = String(candidate.string[offset..<next])
                if !text.allSatisfy(\.isWhitespace), let box = try candidate.boundingBox(for: offset..<next)?.boundingBox {
                    pieces.append(TablePiece(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
                }
                offset = next
            }
        }
        return pieces
    }
    static func pieces(_ page: PDFPage) -> [TablePiece] {
        let string = (page.string ?? "") as NSString
        var result: [TablePiece] = [], offset = 0
        while offset < string.length, result.count < 100_000 {
            let range = string.rangeOfComposedCharacterSequence(at: offset), text = string.substring(with: range)
            if !text.allSatisfy(\.isWhitespace) {
                // PDFKit characterBounds can skip synthesized line breaks; selection ranges follow page.string.
                let rect = page.selection(for: range)?.bounds(for: page) ?? page.characterBounds(at: offset)
                if rect.width > 0, rect.height > 0 {
                    let b = OrderedText.fraction(ofPageRect: rect, cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
                    result.append(TablePiece(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
                }
            }
            offset = NSMaxRange(range)
        }
        return result
    }
    static func pieces(_ lines: [RecognizedLine]) -> [TablePiece] {
        lines.map { TablePiece(text: $0.text, box: CGRect(x: $0.box.minX, y: 1 - $0.box.maxY, width: $0.box.width, height: $0.box.height)) }
    }
    static func boundaries(_ text: String, region: ClosedRange<Double>) throws -> [Double] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",，;； \n")).filter { !$0.isEmpty }
        let numbers = try parts.map { value -> Double in
            guard let v = Double(value), v.isFinite, v > region.lowerBound * 100, v < region.upperBound * 100 else { throw FolioError(message: "分隔线请填写框选范围内的百分比位置，用逗号分开") }; return v / 100
        }.sorted()
        guard numbers.count < 100, zip(numbers, numbers.dropFirst()).allSatisfy({ $1 - $0 > 0.001 }) else { throw FolioError(message: "分隔线过多或过于接近") }
        return [region.lowerBound] + numbers + [region.upperBound]
    }
    static func extract(_ pieces: [TablePiece], x: [Double], y: [Double]) throws -> ExtractedTable {
        guard x.count >= 2, y.count >= 2, (x.count - 1) * (y.count - 1) <= 2000,
              zip(x, x.dropFirst()).allSatisfy({ $0 < $1 }), zip(y, y.dropFirst()).allSatisfy({ $0 < $1 }) else { throw FolioError(message: "行列范围无效，最多支持 2000 个单元格") }
        var cells = Array(repeating: Array(repeating: [TablePiece](), count: x.count - 1), count: y.count - 1)
        for p in pieces {
            let cx = Double(p.box.midX), cy = Double(p.box.midY)
            guard cx >= x[0], cx <= x.last!, cy >= y[0], cy <= y.last!,
                  let c = (0..<(x.count - 1)).first(where: { cx < x[$0 + 1] || $0 == x.count - 2 }),
                  let r = (0..<(y.count - 1)).first(where: { cy < y[$0 + 1] || $0 == y.count - 2 }) else { continue }
            cells[r][c].append(p)
        }
        return ExtractedTable(rows: cells.map { row in row.map { cell in
            var lines: [[TablePiece]] = []
            for p in cell.sorted(by: { $0.box.midY < $1.box.midY }) {
                if let last = lines.last, let first = last.first, abs(first.box.midY - p.box.midY) < max(first.box.height, p.box.height) * 0.55 { lines[lines.count - 1].append(p) }
                else { lines.append([p]) }
            }
            return lines.map { line in
                var text = "", previous: TablePiece?
                for p in line.sorted(by: { $0.box.minX < $1.box.minX }) {
                    if let previous, p.box.minX - previous.box.maxX > min(previous.box.height, p.box.height) * 0.15 { text += " " }
                    text += p.text; previous = p
                }; return text
            }.joined(separator: "\n")
        } })
    }
    /// Long dark runs reveal ordinary ruled tables; text gaps provide a fallback for borderless tables.
    static func suggest(_ pieces: [TablePiece], image: CGImage, region: CGRect) throws -> (x: [Double], y: [Double]) {
        let gray = try VerticalText.Gray(image)
        let x0 = max(0, Int(region.minX * Double(gray.width))), x1 = min(gray.width - 1, Int(region.maxX * Double(gray.width)))
        let y0 = max(0, Int(region.minY * Double(gray.height))), y1 = min(gray.height - 1, Int(region.maxY * Double(gray.height)))
        guard x1 > x0, y1 > y0 else { throw FolioError(message: "请框选较大的表格范围") }
        func rules(vertical: Bool) -> [Double] {
            let start = vertical ? x0 : y0, end = vertical ? x1 : y1
            let otherStart = vertical ? y0 : x0, otherEnd = vertical ? y1 : x1
            let flags = (start...end).map { p -> Int in
                var longest = 0, run = 0
                for q in otherStart...otherEnd { if gray[vertical ? p : q, vertical ? q : p] < 150 { run += 1; longest = max(longest, run) } else { run = 0 } }
                return longest * 100 > (otherEnd - otherStart) * 65 ? 1 : 0
            }
            return VerticalText.runs(flags, minimum: 0).map { Double(start + ($0.lowerBound + $0.upperBound) / 2) / Double(vertical ? gray.width : gray.height) }
        }
        let kept = pieces.filter { region.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        func gaps(vertical: Bool) -> [Double] {
            let spans = kept.map { vertical ? (Double($0.box.minX), Double($0.box.maxX)) : (Double($0.box.minY), Double($0.box.maxY)) }.sorted { $0.0 < $1.0 }
            var merged: [(Double, Double)] = []
            let tolerance = (kept.map { Double($0.box.height) }.sorted().dropFirst(kept.count / 2).first ?? 0.015) * (vertical ? 0.8 : 0.3)
            for s in spans {
                if let last = merged.last, s.0 - last.1 <= tolerance { merged[merged.count - 1].1 = max(last.1, s.1) }
                else { merged.append(s) }
            }
            return zip(merged, merged.dropFirst()).map { ($0.1 + $1.0) / 2 }
        }
        let vx = rules(vertical: true), hy = rules(vertical: false)
        let x = vx.count >= 3 ? vx : gaps(vertical: true), y = hy.count >= 3 ? hy : gaps(vertical: false)
        return (x.filter { $0 > region.minX + 0.005 && $0 < region.maxX - 0.005 }.prefix(29).map { $0 }, y.filter { $0 > region.minY + 0.005 && $0 < region.maxY - 0.005 }.prefix(59).map { $0 })
    }
}
