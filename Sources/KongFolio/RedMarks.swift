import CoreGraphics
import Foundation

extension DocumentServices {
    /// Whether a colour is the red of a seal or of vermilion marks (朱印、朱批): clearly redder than green and blue.
    /// Black ink, grey paper and yellowed paper are not red in this sense.
    static func isRed(r: Int, g: Int, b: Int) -> Bool { r > 110 && r - max(g, b) > 40 }

    /// A grey copy of `image` in which red marks are paper-white, so that a seal over the text, or red punctuation,
    /// is not read as ink. Where black ink lies under a seal it stays black, because black is not red.
    static func withoutRedMarks(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var color = [UInt8](repeating: 255, count: bytesPerRow * height)
        let drawn = color.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw FolioError(message: "无法处理页面颜色。") }
        var grey = [UInt8](repeating: 255, count: width * height)
        for index in 0..<(width * height) {
            let r = Int(color[index * 4]), g = Int(color[index * 4 + 1]), b = Int(color[index * 4 + 2])
            grey[index] = isRed(r: r, g: g, b: b) ? 255 : UInt8((r * 299 + g * 587 + b * 114) / 1000)
        }
        let made: CGImage? = grey.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        return try made.unwrap("无法生成去红图像")
    }
}
