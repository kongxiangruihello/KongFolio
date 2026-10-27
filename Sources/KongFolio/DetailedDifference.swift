import Foundation
import PDFKit
import AppKit

struct TextDifferenceChunk: Identifiable, Equatable {
    var id: Int
    var before: NSRange?
    var after: NSRange?
    var old: String
    var new: String
    var kind: String { before == nil ? "新增" : after == nil ? "删除" : "修改" }
}
struct TextDifferenceResult { var chunks: [TextDifferenceChunk]; var coarse: Bool }
enum DetailedDifference {
    /// Grapheme-aware ranges are converted back to PDFKit's UTF-16 offsets, including emoji and rare ideographs.
    static func text(_ before: String, _ after: String, budget: Int = 8000) throws -> TextDifferenceResult {
        let a = Array(before), b = Array(after)
        guard a != b else { return TextDifferenceResult(chunks: [], coarse: false) }
        var start = 0, endA = a.count, endB = b.count
        while start < min(endA, endB), a[start] == b[start] { start += 1 }
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        var offsetsA = [0], offsetsB = [0]
        for c in a { offsetsA.append(offsetsA.last! + String(c).utf16.count) }
        for c in b { offsetsB.append(offsetsB.last! + String(c).utf16.count) }
        func chunk(_ x: Range<Int>, _ y: Range<Int>, id: Int) -> TextDifferenceChunk {
            TextDifferenceChunk(id: id, before: x.isEmpty ? nil : NSRange(location: offsetsA[x.lowerBound], length: offsetsA[x.upperBound] - offsetsA[x.lowerBound]), after: y.isEmpty ? nil : NSRange(location: offsetsB[y.lowerBound], length: offsetsB[y.upperBound] - offsetsB[y.lowerBound]), old: String(a[x]), new: String(b[y]))
        }
        guard (endA - start) + (endB - start) <= budget else { return TextDifferenceResult(chunks: [chunk(start..<endA, start..<endB, id: 0)], coarse: true) }
        try Task.checkCancellation()
        let x = Array(a[start..<endA]), y = Array(b[start..<endB])
        let changes = y.difference(from: x)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change { case .remove(let i, _, _): removed.insert(i + start); case .insert(let i, _, _): inserted.insert(i + start) }
        }
        var i = start, j = start, chunks: [TextDifferenceChunk] = []
        while i < endA || j < endB {
            try Task.checkCancellation()
            let firstI = i, firstJ = j
            while i < endA, removed.contains(i) { i += 1 }
            while j < endB, inserted.contains(j) { j += 1 }
            if i != firstI || j != firstJ { chunks.append(chunk(firstI..<i, firstJ..<j, id: chunks.count)) }
            else { i += 1; j += 1 }
        }
        return TextDifferenceResult(chunks: chunks, coarse: false)
    }
    struct ImageResult { var overlay: Data; var mask: Data; var regions: [CGRect]; var changedPixels: Int; var shift: CGPoint = .zero; var calibrated = false; var side = 1200 }
    static func image(_ before: PDFPage?, _ after: PDFPage?, dimension: Int = 1200, threshold: Int = 36, automaticAlignment: Bool = false, translation: CGPoint = .zero) throws -> ImageResult {
        let side = max(64, min(2000, dimension)), count = side * side
        func raster(_ page: PDFPage?) throws -> Data {
            var data = Data(repeating: 255, count: count * 4)
            if let page {
                let image = try DocumentServices.render(page, maxDimension: CGFloat(side))
                let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
                try data.withUnsafeMutableBytes { raw in
                    guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FolioError(message: "无法创建差异图像") }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale))
                }
            }
            return data
        }
        let a = try raster(before), rawB = try raster(after)
        let estimate = automaticAlignment && before != nil && after != nil ? try ImageCalibration.estimate(a, rawB, side: side, maxShift: max(2,side/25)) : ImageCalibration.Estimate()
        let manualX = translation.x.isFinite ? Int(max(-80,min(80,translation.x))) : 0
        let manualY = translation.y.isFinite ? Int(max(-80,min(80,translation.y))) : 0
        let dx = estimate.sampleX - manualX, dy = estimate.sampleY - manualY
        let b = dx == 0 && dy == 0 ? rawB : ImageCalibration.shifted(rawB, side: side, sampleX: dx, sampleY: dy)
        var overlay = Data(count: count * 4), mask = Data(repeating: 255, count: count * 4)
        var pixels = 0, bounds: [Int: CGRect] = [:]
        try a.withUnsafeBytes { (left: UnsafeRawBufferPointer) in try b.withUnsafeBytes { (right: UnsafeRawBufferPointer) in
            try overlay.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                mask.withUnsafeMutableBytes { (heat: UnsafeMutableRawBufferPointer) in
                    for p in 0..<count {
                        let k = p * 4, delta = (0..<3).map { abs(Int(left[k + $0]) - Int(right[k + $0])) }.max() ?? 0
                        for channel in 0..<3 { out[k + channel] = UInt8((Int(left[k + channel]) + Int(right[k + channel])) / 2) }; out[k + 3] = 255
                        if delta > threshold {
                            pixels += 1; heat[k] = 235; heat[k + 1] = 55; heat[k + 2] = 65
                            let x = p % side, y = p / side, cell = (y / 48) * 100 + x / 48
                            let rect = CGRect(x: x, y: side - y - 1, width: 1, height: 1)
                            bounds[cell] = bounds[cell].map { $0.union(rect) } ?? rect
                        }
                    }
                }
                try Task.checkCancellation()
            }
        } }
        func png(_ data: Data) throws -> Data {
            let provider = CGDataProvider(data: data as CFData)!
            let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            return try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]).unwrap("无法保存差异图")
        }
        return ImageResult(overlay: try png(overlay), mask: try png(mask), regions: bounds.values.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }, changedPixels: pixels, shift: CGPoint(x: -dx, y: -dy), calibrated: estimate.accepted, side: side)
    }
}
