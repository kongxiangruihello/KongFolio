import PDFKit

enum SpreadGutter {
    /// Looks for a light vertical gap around the center, with content on both sides.
    static func fraction(pixels: [UInt8], width: Int, height: Int) -> Double? {
        guard width >= 50, height >= 20, pixels.count == width * height else { return nil }
        let inset = height / 20
        let columnInk = (0..<width).map { x in
            (inset..<(height - inset)).reduce(0) { $0 + (pixels[$1 * width + x] < 178 ? 1 : 0) }
        }
        let minimumInk = max(8, width * height / 200)
        let lower = width * 30 / 100
        let upper = width * 70 / 100
        let maximumInk = max(1, height / 100)
        var gaps: [Range<Int>] = []
        var start: Int?
        for x in lower...upper {
            if x < upper, columnInk[x] <= maximumInk {
                if start == nil { start = x }
            } else if let beginning = start {
                gaps.append(beginning..<x)
                start = nil
            }
        }
        let center = Double(width) / 2
        let middle: (Range<Int>) -> Double = { (Double($0.lowerBound) + Double($0.upperBound)) / 2 }
        let usable = gaps.filter { gap in
            gap.count >= max(3, width / 60) && gap.count <= width / 5
                && gap.lowerBound > lower && gap.upperBound < upper
                && columnInk[..<gap.lowerBound].reduce(0, +) >= minimumInk
                && columnInk[gap.upperBound...].reduce(0, +) >= minimumInk
        }
        return usable.min { abs(middle($0) - center) < abs(middle($1) - center) }
            .map { middle($0) / Double(width) }
    }

    static func detect(_ data: Data, pages: [Int]) throws -> [Int: Double] {
        let document = try PDFDocument(data: data).unwrap("无法读取 PDF 以检测中缝")
        var result: [Int: Double] = [:]
        for index in pages {
            try Task.checkCancellation()
            let detected = autoreleasepool { () -> Double? in
                guard let page = document.page(at: index),
                      let bitmap = ContentBounds.render(page, width: 180, box: .cropBox) else { return nil }
                return fraction(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)
            }
            result[index] = detected
        }
        return result
    }
}
