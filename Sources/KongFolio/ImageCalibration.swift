import Foundation
import CoreGraphics

/// Translation only, bounded to a small fraction of the canvas. A weak estimate is never applied.
enum ImageCalibration {
    struct Estimate { var sampleX = 0; var sampleY = 0; var accepted = false }
    static func estimate(_ left: Data, _ right: Data, side: Int, maxShift: Int) throws -> Estimate {
        guard side > 0, left.count == side * side * 4, right.count == left.count else { return Estimate() }
        let count = side * side
        var a = [UInt8](repeating: 0, count: count), b = a
        left.withUnsafeBytes { (l: UnsafeRawBufferPointer) in right.withUnsafeBytes { (r: UnsafeRawBufferPointer) in
            for i in 0..<count { let k = i * 4; a[i] = UInt8((Int(l[k]) + Int(l[k+1]) + Int(l[k+2])) / 3); b[i] = UInt8((Int(r[k]) + Int(r[k+1]) + Int(r[k+2])) / 3) }
        } }
        let small = min(160, side), block = Double(side) / Double(small)
        func reduce(_ values: [UInt8]) -> [Int] {
            var output = [Int](repeating: 255, count: small * small)
            for y in 0..<small { for x in 0..<small {
                let x0 = Int(Double(x) * block), x1 = max(x0 + 1, Int(Double(x+1) * block))
                let y0 = Int(Double(y) * block), y1 = max(y0 + 1, Int(Double(y+1) * block))
                var total = 0, n = 0
                for yy in y0..<min(side, y1) { for xx in x0..<min(side, x1) { total += Int(values[yy*side+xx]); n += 1 } }
                output[y*small+x] = total / max(1,n)
            } }
            return output
        }
        let lowA = reduce(a), lowB = reduce(b), bound = max(1, Int(ceil(Double(maxShift) / block)))
        guard lowA.filter({ $0 < 220 }).count >= 20, lowB.filter({ $0 < 220 }).count >= 20 else { return Estimate() }
        func score(_ dx: Int, _ dy: Int) -> Int {
            var result = 0; let margin = bound + 1
            for y in margin..<(small-margin) { for x in margin..<(small-margin) { result += abs(lowA[y*small+x] - lowB[(y+dy)*small+x+dx]) } }
            return result
        }
        var best = score(0,0), bx = 0, by = 0
        for y in -bound...bound { try Task.checkCancellation(); for x in -bound...bound {
            let value = score(x,y)
            if value < best { best = value; bx = x; by = y }
        } }
        let radius = max(1, Int(ceil(block))), centerX = Int((Double(bx)*block).rounded()), centerY = Int((Double(by)*block).rounded())
        let stride = max(1, side/140), margin = maxShift + radius + 1
        guard margin * 2 < side else { return Estimate() }
        func precise(_ dx: Int, _ dy: Int) -> Int {
            var score = 0, y = margin
            while y < side-margin { var x = margin; while x < side-margin { score += abs(Int(a[y*side+x])-Int(b[(y+dy)*side+x+dx])); x += stride }; y += stride }
            return score
        }
        let baseline = precise(0,0)
        var fine = baseline, fx = 0, fy = 0
        for y in max(-maxShift,centerY-radius)...min(maxShift,centerY+radius) {
            try Task.checkCancellation()
            for x in max(-maxShift,centerX-radius)...min(maxShift,centerX+radius) {
                let value = precise(x,y)
                if value < fine { fine = value; fx = x; fy = y }
            }
        }
        guard baseline > 0, Double(fine) < Double(baseline)*0.8 else { return Estimate() }
        return Estimate(sampleX: fx, sampleY: fy, accepted: true)
    }
    static func shifted(_ data: Data, side: Int, sampleX: Int, sampleY: Int) -> Data {
        var result = Data(repeating: 255, count: data.count)
        guard data.count == side*side*4, abs(sampleX)<side, abs(sampleY)<side else { return result }
        let firstX = max(0,-sampleX), lastX = min(side,side-sampleX)
        data.withUnsafeBytes { source in result.withUnsafeMutableBytes { destination in
            guard let a = source.baseAddress, let b = destination.baseAddress else { return }
            for y in max(0,-sampleY)..<min(side,side-sampleY) {
                b.advanced(by:(y*side+firstX)*4).copyMemory(from:a.advanced(by:((y+sampleY)*side+firstX+sampleX)*4),byteCount:(lastX-firstX)*4)
            }
        } }
        return result
    }
}
