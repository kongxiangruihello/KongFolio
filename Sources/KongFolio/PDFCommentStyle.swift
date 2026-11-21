import AppKit
import PDFKit

struct PDFCommentStyle: Codable, Equatable {
    enum Typeface: String, Codable, CaseIterable {
        case system = "系统字体"
        case serif = "衬线"
        case monospaced = "等宽"
    }

    enum Frame: String, Codable, CaseIterable {
        case none = "无边框"
        case solid = "实线"
        case dashed = "虚线"
    }

    enum Alignment: String, Codable, CaseIterable {
        case left = "左对齐"
        case center = "居中"
        case right = "右对齐"

        var native: NSTextAlignment {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    var typeface: Typeface = .system
    var fontSize: Int = 12
    var bold = false
    var italic = false
    var alignment: Alignment = .left
    var width: Int = 220
    var height: Int = 88
    var automaticHeight = true
    var frame: Frame = .solid
    var textColor: UInt32 = 0x1A2638
    var backgroundColor: UInt32 = 0xE8F2FF
    var transparent = false

    var font: NSFont {
        let size = CGFloat(fontSize)
        let weight: NSFont.Weight = bold ? .bold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font: NSFont
        switch typeface {
        case .system: font = base
        case .serif: font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .monospaced: font = .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }

    var ink: NSColor { Self.color(textColor) }
    var fill: NSColor { transparent ? .clear : Self.color(backgroundColor) }

    var normalized: Self {
        var style = self
        style.fontSize = min(max(fontSize, 8), 72)
        style.width = min(max(width, 80), 1200)
        style.height = min(max(height, 28), 1200)
        return style
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func rgb(_ color: NSColor) -> UInt32? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return UInt32((min(max(color.redComponent, 0), 1) * 255).rounded()) << 16
            | UInt32((min(max(color.greenComponent, 0), 1) * 255).rounded()) << 8
            | UInt32((min(max(color.blueComponent, 0), 1) * 255).rounded())
    }
}
