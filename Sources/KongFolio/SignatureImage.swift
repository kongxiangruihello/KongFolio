import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum InkTint: String, CaseIterable, Identifiable, Codable {
    case original = "原色", black = "黑色", blue = "蓝色", red = "红色"
    var id: String { rawValue }
    /// nil keeps each pixel's own colour.
    var rgb: (r: Double, g: Double, b: Double)? {
        switch self {
        case .original: return nil
        case .black: return (0, 0, 0)
        case .blue: return (0.04, 0.2, 0.72)
        case .red: return (0.78, 0.08, 0.08)
        }
    }
}

/// How a photo or scan of a signature is turned into a stamp with a transparent background.
struct SignatureOptions: Equatable {
    var removeBackground = true
    /// Pixels lighter than this (after the light has been evened out) become transparent. 0...1
    var threshold = 0.8
    /// Picks the strength from the picture itself (ink and paper are told apart by their brightness histogram);
    /// `threshold` is used only when this is off.
    var automatic = true
    /// Divides out uneven lighting (a shadow across the paper, a page photographed at an angle).
    var evenOutLight = true
    var tint = InkTint.black
    var trim = true
}

enum SignatureImage {
    static let maximumDimension = 1600

    /// Reads an image file (PNG, JPEG, HEIC, TIFF, ...) with its orientation applied and at a reasonable size.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// An image on the clipboard (copied from Preview, Photos, a screenshot, ...).
    @MainActor static func fromClipboard() -> CGImage? {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Straight (not premultiplied) RGBA pixels, scaled down so the longer side is at most `maxDimension`.
    static func pixels(of image: CGImage, maxDimension: Int = maximumDimension) -> (data: [UInt8], width: Int, height: Int)? {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Int(buffer[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 { buffer[index + channel] = UInt8(min(255, Int(buffer[index + channel]) * 255 / alpha)) }
        }
        return (buffer, width, height)
    }

    /// Sliding-window maximum along one axis (window of `2 * radius + 1`).
    private static func windowMaximum(_ values: [Float], width: Int, height: Int, radius: Int, horizontal: Bool) -> [Float] {
        var output = values
        let lines = horizontal ? height : width, length = horizontal ? width : height
        for line in 0..<lines {
            for position in 0..<length {
                let low = max(0, position - radius), high = min(length - 1, position + radius)
                var best: Float = 0
                for other in low...high {
                    let value = horizontal ? values[line * width + other] : values[other * width + line]
                    if value > best { best = value }
                }
                if horizontal { output[line * width + position] = best } else { output[position * width + line] = best }
            }
        }
        return output
    }

    private static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        func pass(_ input: [Float], horizontal: Bool) -> [Float] {
            var output = input
            let lines = horizontal ? height : width, length = horizontal ? width : height
            for line in 0..<lines {
                for position in 0..<length {
                    let low = max(0, position - radius), high = min(length - 1, position + radius)
                    var sum: Float = 0
                    for other in low...high { sum += horizontal ? input[line * width + other] : input[other * width + line] }
                    let mean = sum / Float(high - low + 1)
                    if horizontal { output[line * width + position] = mean } else { output[position * width + line] = mean }
                }
            }
            return output
        }
        return pass(pass(values, horizontal: true), horizontal: false)
    }

    /// Otsu's method on the brightness histogram: the level that best separates dark ink from light paper,
    /// moved a little towards the paper so the soft edge of a stroke stays.
    static func autoCutoff(_ light: [Float]) -> Float {
        let bins = 64
        var histogram = [Double](repeating: 0, count: bins)
        for value in light { histogram[min(bins - 1, max(0, Int(value * Float(bins))))] += 1 }
        let total = Double(light.count)
        guard total > 0 else { return 0.8 }
        var sumAll = 0.0
        for (index, count) in histogram.enumerated() { sumAll += Double(index) * count }
        var weightBackground = 0.0, sumBackground = 0.0, best = 0.0, threshold = 0
        for index in 0..<bins {
            weightBackground += histogram[index]
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }
            sumBackground += Double(index) * histogram[index]
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sumAll - sumBackground) / weightForeground
            let between = weightBackground * weightForeground * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if between > best { best = between; threshold = index }
        }
        let level = Float(threshold + 1) / Float(bins)
        return min(max(level + 0.1, 0.45), 0.95)
    }

    /// Turns a signature photo into ink on a transparent background; nil when no ink is found.
    static func process(_ image: CGImage, options: SignatureOptions) -> CGImage? {
        guard let loaded = Self.pixels(of: image) else { return nil }
        var pixels = loaded.data
        let width = loaded.width, height = loaded.height
        if options.removeBackground {
            // Brightness of every pixel as it would look on white paper.
            var light = [Float](repeating: 1, count: width * height)
            for index in 0..<(width * height) {
                let alpha = Float(pixels[index * 4 + 3]) / 255
                let luma = (0.299 * Float(pixels[index * 4]) + 0.587 * Float(pixels[index * 4 + 1]) + 0.114 * Float(pixels[index * 4 + 2])) / 255
                light[index] = luma * alpha + (1 - alpha)
            }
            if options.evenOutLight {
                // The paper brightness around each pixel is the local maximum; dividing by it flattens shadows.
                // Worked out on a 4x smaller grid; the paper brightness changes slowly.
                let block = 4
                let cw = (width + block - 1) / block, ch = (height + block - 1) / block
                var coarse = [Float](repeating: 0, count: cw * ch)
                for y in 0..<height { for x in 0..<width {
                    let c = (y / block) * cw + x / block
                    if light[y * width + x] > coarse[c] { coarse[c] = light[y * width + x] }
                } }
                let radius = max(3, min(cw, ch) / 12)
                coarse = windowMaximum(windowMaximum(coarse, width: cw, height: ch, radius: radius, horizontal: true), width: cw, height: ch, radius: radius, horizontal: false)
                coarse = boxBlur(coarse, width: cw, height: ch, radius: max(1, radius / 2))
                var paper = [Float](repeating: 1, count: width * height)
                for y in 0..<height { for x in 0..<width { paper[y * width + x] = coarse[(y / block) * cw + x / block] } }
                for index in 0..<light.count { light[index] = min(1, light[index] / max(paper[index], 0.08)) }
            }
            let cutoff = options.automatic ? autoCutoff(light) : Float(min(max(options.threshold, 0.05), 0.98))
            let band: Float = 0.15
            for index in 0..<(width * height) {
                let ink = min(max((cutoff - light[index]) / band, 0), 1)
                let base = index * 4
                var red = Float(pixels[base]) / 255, green = Float(pixels[base + 1]) / 255, blue = Float(pixels[base + 2]) / 255
                if let tint = options.tint.rgb { red = Float(tint.r); green = Float(tint.g); blue = Float(tint.b) }
                pixels[base] = UInt8((red * ink * 255).rounded())          // premultiplied
                pixels[base + 1] = UInt8((green * ink * 255).rounded())
                pixels[base + 2] = UInt8((blue * ink * 255).rounded())
                pixels[base + 3] = UInt8((ink * 255).rounded())
            }
        } else {
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[index + 3])
                for channel in 0..<3 { pixels[index + channel] = UInt8(Int(pixels[index + channel]) * alpha / 255) }
            }
        }
        guard let result = pixels.withUnsafeMutableBytes({ raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }) else { return nil }
        return trimmed(result, pixels: pixels, width: width, height: height, crop: options.trim && options.removeBackground)
    }

    /// Crops to the ink (with a little margin); nil when nothing is left.
    private static func trimmed(_ image: CGImage, pixels: [UInt8], width: Int, height: Int, crop: Bool) -> CGImage? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 12 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        guard crop else { return image }
        let margin = 6
        let rect = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                          width: min(width, maxX + margin + 1) - max(0, minX - margin), height: min(height, maxY + margin + 1) - max(0, minY - margin))
        return image.cropping(to: rect)
    }
}
