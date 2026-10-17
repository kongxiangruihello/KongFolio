import CoreGraphics
import Foundation
import Vision

/// Vertical (竖排) text recognition. VNRecognizeTextRequest reads horizontal lines only, so this
/// follows the approach an Apple DTS engineer describes on the developer forums: cut the page
/// into columns (right to left), cut each column into character cells, lay the cells out as
/// horizontal rows, recognize those rows, then map every character back to its cell on the page.
enum VerticalText {
    struct Column {
        var x0: Int
        var x1: Int
        var cells: [ClosedRange<Int>] // top-down pixel rows
    }

    /// 8-bit grayscale copy of the image; row 0 is the top of the image.
    struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var buffer = [UInt8](repeating: 255, count: width * height)
            let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { throw FolioError(message: "竖排识别：无法读取页面图像。") }
            pixels = buffer
        }
        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
        subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
    }

    /// Paints over the rules of the printed frame (版框, 界栏) and dark scanner edges. A rule that runs across the
    /// whole page joins every column of text into one, and then no column can be found at all. Rows that are dark over
    /// more than half of the width and columns dark over more than 65 % of the height are rules: text never gets there
    /// (the densest text row of a real page measured 31 %, its densest column 46 %). A page that is mostly dark, where
    /// that would wipe out a large part of the picture, is left alone.
    static func clearingFrame(_ gray: Gray, level: UInt8) -> Gray {
        let width = gray.width, height = gray.height
        var rowInk = [Int](repeating: 0, count: height), columnInk = [Int](repeating: 0, count: width)
        for y in 0..<height { for x in 0..<width where gray[x, y] < level { rowInk[y] += 1; columnInk[x] += 1 } }
        let rules = rowInk.map { $0 * 2 > width }
        let bars = columnInk.map { $0 * 100 > height * 65 }
        let ruleCount = rules.filter { $0 }.count, barCount = bars.filter { $0 }.count
        guard ruleCount + barCount > 0, ruleCount * 100 <= height * 15, barCount * 100 <= width * 15 else { return gray }
        func grown(_ flags: [Bool], by amount: Int) -> [Bool] {
            var result = flags
            for index in flags.indices where flags[index] {
                for step in -amount...amount where result.indices.contains(index + step) { result[index + step] = true }
            }
            return result
        }
        let margin = max(2, min(width, height) / 700)
        let clearRows = grown(rules, by: margin), clearColumns = grown(bars, by: margin)
        var pixels = gray.pixels
        for y in 0..<height {
            for x in 0..<width where clearRows[y] || clearColumns[x] { pixels[y * width + x] = 255 }
        }
        return Gray(width: width, height: height, pixels: pixels)
    }

    /// Otsu's threshold on the grayscale histogram, limited so near-blank pages don't pick up paper texture.
    static func threshold(_ gray: Gray) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for value in gray.pixels { histogram[Int(value)] += 1 }
        let total = gray.pixels.count
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var backgroundSum = 0.0, backgroundWeight = 0, best = 0.0, chosen = 128
        for level in 0..<256 {
            backgroundWeight += histogram[level]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            guard foregroundWeight > 0 else { break }
            backgroundSum += Double(level * histogram[level])
            let meanBackground = backgroundSum / Double(backgroundWeight)
            let meanForeground = (sum - backgroundSum) / Double(foregroundWeight)
            let between = Double(backgroundWeight) * Double(foregroundWeight) * pow(meanBackground - meanForeground, 2)
            if between > best { best = between; chosen = level }
        }
        return UInt8(min(200, max(60, chosen)))
    }

    static func runs(_ values: [Int], minimum: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var start: Int?
        for (index, value) in values.enumerated() {
            if value > minimum { if start == nil { start = index } }
            else if let s = start { result.append(s...(index - 1)); start = nil }
        }
        if let s = start { result.append(s...(values.count - 1)) }
        return result
    }

    static func merge(_ runs: [ClosedRange<Int>], gap: Int, maximumLength: Int = .max) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for run in runs {
            if let last = result.last, run.lowerBound - last.upperBound - 1 <= gap, run.upperBound - last.lowerBound + 1 <= maximumLength {
                result[result.count - 1] = last.lowerBound...run.upperBound
            } else {
                result.append(run)
            }
        }
        return result
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// Rules that are broken into pieces (a printed frame is rarely one clean line) escape `clearingFrame`: this paints
    /// over every run of dark pixels longer than a few characters, horizontally or vertically, plus two pixels around
    /// it. No stroke of a character comes close to that length. If it would wipe out a large part of the picture
    /// (a dark scan) nothing is changed.
    static func clearingLongRuns(_ gray: Gray, level: UInt8) -> Gray {
        let width = gray.width, height = gray.height
        let length = max(80, Int(0.06 * Double(min(width, height))))
        var kill = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            var x = 0
            while x < width {
                guard gray[x, y] < level else { x += 1; continue }
                var end = x
                while end < width, gray[end, y] < level { end += 1 }
                if end - x >= length { for index in x..<end { kill[y * width + index] = true } }
                x = end
            }
        }
        for x in 0..<width {
            var y = 0
            while y < height {
                guard gray[x, y] < level else { y += 1; continue }
                var end = y
                while end < height, gray[x, end] < level { end += 1 }
                if end - y >= length { for index in y..<end { kill[index * width + x] = true } }
                y = end
            }
        }
        let killed = kill.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard killed > 0, killed * 100 <= width * height * 15 else { return gray }
        var pixels = gray.pixels
        for y in 0..<height {
            for x in 0..<width where kill[y * width + x] {
                for dy in max(0, y - 2)...min(height - 1, y + 2) { for dx in max(0, x - 2)...min(width - 1, x + 2) { pixels[dy * width + dx] = 255 } }
            }
        }
        return Gray(width: width, height: height, pixels: pixels)
    }

    /// A run that is much wider than a column holds several columns that touch (two narrow columns of small print,
    /// or a heading beside its note). Cut it where the ink is thinnest.
    static func splitWide(_ range: ClosedRange<Int>, ink: [Int], typical: Int) -> [ClosedRange<Int>] {
        let width = range.count
        guard typical > 0, width * 10 > typical * 16 else { return [range] }
        let parts = max(1, Int((Double(width) / (Double(typical) * 1.3)).rounded()))
        if parts == 1 { return [range] }
        if parts > 6 { return [] }                       // a blob that is not text
        var cuts: [Int] = []
        for k in 1..<parts {
            let ideal = range.lowerBound + width * k / parts
            let low = max(range.lowerBound + typical * 4 / 10, ideal - typical * 35 / 100)
            let high = min(range.upperBound - typical * 4 / 10, ideal + typical * 35 / 100)
            guard high > low else { continue }
            var best = low
            for x in low...high where ink[x] < ink[best] { best = x }
            cuts.append(best)
        }
        var result: [ClosedRange<Int>] = []
        var start = range.lowerBound
        for cut in cuts {
            if cut - 1 >= start { result.append(start...(cut - 1)) }
            start = cut + 1
        }
        if start <= range.upperBound { result.append(start...range.upperBound) }
        return result
    }

    /// Thin cells (a stroke like 一 is thin too) that are really pieces of the printed frame: ones lying at the same
    /// height in many columns, and ones left alone at the top or bottom of a column, well away from its text.
    static func removingRuleFragments(_ columns: [Column]) -> [Column] {
        func thin(_ cell: ClosedRange<Int>, _ column: Column) -> Bool { cell.count < (column.x1 - column.x0 + 1) * 3 / 10 }
        let typical = median(columns.map { $0.x1 - $0.x0 + 1 })
        let tolerance = max(6, typical / 4)
        var thinCentres: [(column: Int, centre: Int)] = []
        for (index, column) in columns.enumerated() {
            for cell in column.cells where thin(cell, column) { thinCentres.append((index, (cell.lowerBound + cell.upperBound) / 2)) }
        }
        func aligned(_ centre: Int) -> Bool {
            Set(thinCentres.filter { abs($0.centre - centre) <= tolerance }.map(\.column)).count >= max(3, columns.count * 4 / 10)
        }
        return columns.compactMap { column in
            let size = column.x1 - column.x0 + 1
            var cells = column.cells.filter { !(thin($0, column) && aligned(($0.lowerBound + $0.upperBound) / 2)) }
            if cells.count > 1, let first = cells.first, thin(first, column), cells[1].lowerBound - first.upperBound > size * 35 / 100 { cells.removeFirst() }
            if cells.count > 1, let last = cells.last, thin(last, column), last.lowerBound - cells[cells.count - 2].upperBound > size * 35 / 100 { cells.removeLast() }
            return cells.isEmpty ? nil : Column(x0: column.x0, x1: column.x1, cells: cells)
        }
    }

    /// Finds text columns (right to left) and the character cells inside each.
    static func layout(_ original: Gray) -> [Column] {
        let level = threshold(original)
        let gray = clearingLongRuns(clearingFrame(original, level: level), level: level)
        var columnInk = [Int](repeating: 0, count: gray.width)
        for y in 0..<gray.height { for x in 0..<gray.width where gray[x, y] < level { columnInk[x] += 1 } }
        // Specks and the thin remains of a frame must not bridge the gap between two columns: a column counts as ink
        // only where it holds at least 4 % of what the inkiest columns hold.
        let inked = columnInk.filter { $0 > 0 }.sorted()
        let peak = inked.isEmpty ? 0 : inked[min(inked.count - 1, inked.count * 95 / 100)]
        var columns = runs(columnInk, minimum: max(1, gray.height / 400, peak / 25))
        let typical = median(columns.map(\.count).filter { $0 > 3 })
        guard typical > 0 else { return [] }
        // Strokes inside one character (川, 小) leave narrow gaps; column rules (界栏) are thin runs.
        columns = merge(columns, gap: max(1, typical / 4))
        var width = median(columns.map(\.count))
        columns = columns.filter { $0.count >= max(4, width / 2) }
        width = median(columns.map(\.count))
        columns = columns.flatMap { splitWide($0, ink: columnInk, typical: width) }.filter { $0.count >= max(4, width * 7 / 10) }
        let found: [Column] = columns.reversed().compactMap { range in
            var rowInk = [Int](repeating: 0, count: gray.height)
            for y in 0..<gray.height { for x in range where gray[x, y] < level { rowInk[y] += 1 } }
            let size = range.count
            var cells = merge(runs(rowInk, minimum: 0), gap: max(1, size / 7), maximumLength: size * 5 / 4)
            // Touching characters: split tall runs into roughly square cells.
            cells = cells.flatMap { run -> [ClosedRange<Int>] in
                guard run.count > size * 3 / 2 else { return [run] }
                let parts = max(2, Int((Double(run.count) / Double(size)).rounded()))
                let step = Double(run.count) / Double(parts)
                return (0..<parts).map { part in
                    let lower = run.lowerBound + Int(Double(part) * step)
                    let upper = part == parts - 1 ? run.upperBound : run.lowerBound + Int(Double(part + 1) * step) - 1
                    return lower...upper
                }
            }
            // Drop specks such as 句读 marks: small in both directions. 一 is short but spans the column.
            cells = cells.filter { cell in
                guard cell.count < size * 3 / 10 else { return true }
                var left = range.upperBound, right = range.lowerBound
                for y in cell { for x in range where gray[x, y] < level { left = min(left, x); right = max(right, x) } }
                return right - left + 1 >= size * 4 / 10
            }
            return cells.isEmpty ? nil : Column(x0: range.lowerBound, x1: range.upperBound, cells: cells)
        }
        return removingRuleFragments(found)
    }

    static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let gray = try Gray(image)
        let columns = layout(gray)
        guard !columns.isEmpty else { return [] }
        // One cell size for the whole page, from the typical column: a single odd cell (two touching columns, a blob) must
        // not blow it up, or every character ends up tiny and far from the next. Larger pieces are scaled down to fit.
        let cellSize = max(8, median(columns.map { $0.x1 - $0.x0 + 1 }) * 12 / 10)
        let pad = max(4, cellSize / 6), rowHeight = cellSize + pad * 2, advance = cellSize + pad / 2
        let canvasWidth = pad + advance * (columns.map(\.cells.count).max() ?? 1)
        let canvasHeight = rowHeight * columns.count
        guard canvasWidth * canvasHeight <= 120_000_000,
              let ctx = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw FolioError(message: "竖排识别：页面过大，请降低识别精度。")
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        for (row, column) in columns.enumerated() {
            for (index, cell) in column.cells.enumerated() {
                let source = CGRect(x: column.x0, y: cell.lowerBound, width: column.x1 - column.x0 + 1, height: cell.count)
                guard let piece = image.cropping(to: source) else { continue }
                let scale = min(1, Double(cellSize) / Double(max(piece.width, piece.height)))
                let drawnWidth = max(1, Int(Double(piece.width) * scale)), drawnHeight = max(1, Int(Double(piece.height) * scale))
                let x = pad + index * advance + (cellSize - drawnWidth) / 2
                let top = row * rowHeight + pad + (cellSize - drawnHeight) / 2
                ctx.interpolationQuality = .high
                ctx.draw(piece, in: CGRect(x: x, y: canvasHeight - top - drawnHeight, width: drawnWidth, height: drawnHeight))
            }
        }
        guard let strip = ctx.makeImage() else { throw FolioError(message: "竖排识别：无法生成识别图像。") }
        // Vision ignores text shorter than 1/32 of the image height by default. With many columns the canvas is tall and
        // every character is a small part of it (about 3 % for fifteen columns), so most of a page would be dropped
        // (a real page gave fewer than 100 characters out of about 450). Ask for text down to a fraction of the cell.
        let relativeCell = Float(cellSize) / Float(canvasHeight)
        let observations = try recognizeRows(strip, languages: languages, minimumTextHeight: max(0.002, min(0.03, relativeCell * 0.4)))
        var rowsText = [[(x: CGFloat, text: String, confidence: Float)]](repeating: [], count: columns.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let center = (1 - observation.boundingBox.midY) * CGFloat(canvasHeight)
            let row = min(columns.count - 1, max(0, Int(center / CGFloat(rowHeight))))
            rowsText[row].append((observation.boundingBox.minX, candidate.string, candidate.confidence))
        }
        let width = CGFloat(gray.width), height = CGFloat(gray.height)
        var lines: [RecognizedLine] = []
        for (row, column) in columns.enumerated() {
            let parts = rowsText[row].sorted { $0.x < $1.x }
            let text = parts.map(\.text).joined().filter { !$0.isWhitespace }
            guard !text.isEmpty else { continue }
            let confidence = parts.map(\.confidence).min() ?? 0
            let characters = Array(text)
            if characters.count == column.cells.count {
                // One recognized character per cell: exact placement, so search highlights land on the characters.
                for (character, cell) in zip(characters, column.cells) {
                    let box = CGRect(x: CGFloat(column.x0) / width, y: (height - CGFloat(cell.upperBound + 1)) / height, width: CGFloat(column.x1 - column.x0 + 1) / width, height: CGFloat(cell.count) / height)
                    lines.append(RecognizedLine(text: String(character), box: box, confidence: confidence))
                }
            } else {
                let top = column.cells.first!.lowerBound, bottom = column.cells.last!.upperBound
                let box = CGRect(x: CGFloat(column.x0) / width, y: (height - CGFloat(bottom + 1)) / height, width: CGFloat(column.x1 - column.x0 + 1) / width, height: CGFloat(bottom - top + 1) / height)
                lines.append(RecognizedLine(text: text, box: box, confidence: confidence, approximate: true))
            }
        }
        return lines
    }

    static func recognizeRows(_ image: CGImage, languages: [String], minimumTextHeight: Float = 0.03125) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = minimumTextHeight
        let supported = Set(DocumentServices.supportedOCRLanguages)
        let chosen = languages.filter { supported.isEmpty || supported.contains($0) }
        request.recognitionLanguages = chosen.isEmpty ? ["zh-Hant", "zh-Hans"] : chosen
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }
}
