import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Typed replacements for the string flags used before 0.4. Raw values keep the
// exact strings that 0.2/0.3 project files contain, so old projects still decode.

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case document = "Document"
    case image = "Image"
    var id: String { rawValue }
    var title: String { self == .document ? "文档" : "图片" }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select = "选择"
    case edit = "编辑标注"
    case note = "批注"
    case textBox = "文字框"
    case pen = "画笔"
    case arrow = "箭头"
    case signature = "签名"
    case region = "区域摘录"
    var id: String { rawValue }
    var title: String { rawValue }
    var draws: Bool { self == .pen || self == .arrow || self == .signature }
}

/// How a pen or arrow stroke looks, from the width and highlighter settings.
struct PenStyle: Equatable {
    var width: Double
    var alpha: Double

    static func make(width: Double, highlighter: Bool, arrow: Bool) -> PenStyle {
        let clamped = min(max(width, 0.5), 24)
        // A highlighter is a broad, see-through marker; arrows keep a clean line whatever the setting.
        if highlighter && !arrow { return PenStyle(width: max(10, clamped * 4), alpha: 0.35) }
        return PenStyle(width: clamped, alpha: 1)
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case pages = "页面"
    case outline = "目录"
    case bookmarks = "书签"
    case search = "搜索"
    case notes = "摘录"
    var id: String { rawValue }
    var title: String { rawValue }
}

enum ReadingLayout: String, Codable, CaseIterable, Identifiable {
    case continuous = "连续"
    case single = "单页"
    case twoUp = "双页"
    var id: String { rawValue }
    var title: String { rawValue }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case pdf = "PDF"
    case png = "PNG"
    case jpg = "JPG"
    case tiff = "TIFF"
    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .jpg: return .jpeg
        case .tiff: return .tiff
        }
    }
    var suffix: String { self == .jpg ? "jpg" : rawValue.lowercased() }
}

enum ExportScope: String, Codable, CaseIterable, Identifiable {
    case all = "全部页面"
    case current = "当前页面"
    case selected = "选中页面"
    var id: String { rawValue }
}

enum PDFExportMode: String, Codable, CaseIterable, Identifiable {
    case preserve = "保留原始内容"
    case optimized = "压缩图片（保留文字）"
    case raster = "图片型 PDF"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .preserve: return "保留页面原始内容、尺寸、目录和可编辑标注，不重新采样。"
        case .optimized: return "用 PDFKit 把页面中的图片重新编码为适合屏幕的 JPEG；文字、矢量内容、链接和目录保留。不保证每个文件都会变小。"
        case .raster: return "整页重新渲染为图片；文字、链接和标注固化，体积由 DPI 和质量决定。"
        }
    }
}

enum MarkupStyle: String, CaseIterable, Identifiable {
    case highlight = "高亮"
    case underline = "下划线"
    case strikeOut = "删除线"
    var id: String { rawValue }
    var subtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        }
    }
}

enum MarkupColor: String, CaseIterable, Identifiable {
    case yellow = "黄"
    case green = "绿"
    case blue = "蓝"
    case pink = "粉"
    var id: String { rawValue }
    var nsColor: NSColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .pink: return .systemPink
        }
    }
}

/// Everything KongFolio keeps per page, stored in one array aligned with the document.
/// Page operations remap this array once instead of rewriting several index-keyed dictionaries.
struct PageMeta {
    var recipe: ImageRecipe?
    var draft: ImageAdjustments?
    var ocrOriginal: Data?
    var ocrRegions: [RecognizedLine]?
}

struct OCRLanguagePreset: Identifiable, Hashable {
    let id: String
    let title: String
    let languages: [String]
}

struct OCRSettings: Codable, Equatable {
    var languages = ["zh-Hans", "en-US"]
    var dpi = 300
    var vertical = false
    /// Pages with at least this many non-whitespace characters already count as text pages and are skipped.
    var minimumTextCharacters = 20
    /// Recognise pages even when they already have some text. Scans from other OCR software often carry only the
    /// headings; such a page has "text" but not its text. Optional so settings saved before this existed still load.
    var ignoreTextLayer: Bool? = nil
    var ignoresTextLayer: Bool {
        get { ignoreTextLayer ?? false }
        set { ignoreTextLayer = newValue ? true : nil }
    }

    static let presets: [OCRLanguagePreset] = [
        OCRLanguagePreset(id: "hans", title: "简体中文 + 英文", languages: ["zh-Hans", "en-US"]),
        OCRLanguagePreset(id: "hant", title: "繁体中文 + 英文", languages: ["zh-Hant", "en-US"]),
        OCRLanguagePreset(id: "mixed", title: "繁体优先 + 简体 + 英文", languages: ["zh-Hant", "zh-Hans", "en-US"]),
        OCRLanguagePreset(id: "ja", title: "日文 + 繁体中文", languages: ["ja-JP", "zh-Hant"]),
        OCRLanguagePreset(id: "en", title: "英文", languages: ["en-US"]),
    ]
    static let dpiChoices = [200, 300, 400]
    static let defaultsKey = "KongFolio.OCRSettings"

    var presetID: String { Self.presets.first { $0.languages == languages }?.id ?? Self.presets[0].id }

    static func load(_ defaults: UserDefaults = .standard) -> OCRSettings {
        guard let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(OCRSettings.self, from: data) else { return OCRSettings() }
        return value
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Bibliographic details used when exporting excerpts, so notes can be cited without reopening the book.
struct Bibliography: Codable, Equatable {
    var author = ""
    var title = ""
    var publisher = ""
    var year = ""
    var edition = ""

    var isEmpty: Bool { [author, title, publisher, year, edition].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// A plain Chinese citation: 作者：《书名》，版本，出版者，年份。
    var citation: String {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var head = ""
        if !clean(author).isEmpty { head += clean(author) + "：" }
        if !clean(title).isEmpty { head += "《" + clean(title) + "》" }
        let tail = [clean(edition), clean(publisher), clean(year)].filter { !$0.isEmpty }
        if !tail.isEmpty { head += (head.isEmpty ? "" : "，") + tail.joined(separator: "，") }
        return head
    }

    func citation(page label: String) -> String {
        let base = citation
        return base.isEmpty ? "第 \(label) 页" : base + "，第 \(label) 页。"
    }
}

enum Brand {
    /// Shared kong-series blue, sampled from the KongFetch icon (#3B73EF).
    static let accent = Color(red: 59 / 255, green: 115 / 255, blue: 239 / 255)
    static let accentNS = NSColor(srgbRed: 59 / 255, green: 115 / 255, blue: 239 / 255, alpha: 1)
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

/// Whether a person is there to answer dialogs. Test runs have no one to ask, and creating a view in a test can make
/// `NSApp` exist, so the presence of `NSApp` alone is not enough: a modal alert there would wait forever.
enum AppEnvironment {
    static let isTestRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.processName == "KongFolioTests"
    }()

    @MainActor static var isInteractive: Bool { NSApp != nil && !isTestRun }
}
