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

    /// Finds text columns (right to left) and the character cells inside each.
    static func layout(_ original: Gray) -> [Column] {
        let level = threshold(original)
        let gray = clearingFrame(original, level: level)
        var columnInk = [Int](repeating: 0, count: gray.width)
        for y in 0..<gray.height { for x in 0..<gray.width where gray[x, y] < level { columnInk[x] += 1 } }
        var columns = runs(columnInk, minimum: max(1, gray.height / 400))
        let typical = median(columns.map(\.count).filter { $0 > 3 })
        guard typical > 0 else { return [] }
        // Strokes inside one character (川, 小) leave narrow gaps; column rules (界栏) are thin runs.
        columns = merge(columns, gap: max(1, typical / 4)).filter { $0.count >= max(4, typical * 35 / 100) }
        let width = median(columns.map(\.count))
        columns = columns.filter { $0.count <= width * 2 }
        return columns.reversed().compactMap { range in
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
    }

    static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let gray = try Gray(image)
        let columns = layout(gray)
        guard !columns.isEmpty else { return [] }
        let cellSize = columns.flatMap { [$0.x1 - $0.x0 + 1] + $0.cells.map(\.count) }.max() ?? 1
        let pad = max(4, cellSize / 5), rowHeight = cellSize + pad * 2, advance = cellSize + pad
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
                let x = pad + index * advance + (cellSize - piece.width) / 2
                let top = row * rowHeight + pad + (cellSize - piece.height) / 2
                ctx.draw(piece, in: CGRect(x: x, y: canvasHeight - top - piece.height, width: piece.width, height: piece.height))
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
