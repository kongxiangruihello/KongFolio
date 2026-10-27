import Foundation

enum ToolbarAction: String, Codable, CaseIterable, Identifiable {
    case newPDF, newMarkdown, newText, newHTML, split, annotate, tools, open, save, close, export, ocr, signature, print
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newPDF: return "新建 PDF"
        case .newMarkdown: return "新建 Markdown"
        case .newText: return "新建文本文件"
        case .newHTML: return "新建 HTML"
        case .split: return "并排"
        case .annotate: return "标注"
        case .tools: return "快捷工具"
        case .open: return "打开"
        case .save: return "保存"
        case .close: return "关闭"
        case .export: return "导出"
        case .ocr: return "OCR 识别"
        case .signature: return "图片签名"
        case .print: return "打印"
        }
    }
    var symbol: String {
        switch self {
        case .newPDF: return "doc.badge.plus"
        case .newMarkdown: return "square.and.pencil"
        case .newText: return "doc.plaintext"
        case .newHTML: return "chevron.left.forwardslash.chevron.right"
        case .split: return "rectangle.split.2x1"
        case .annotate: return "pencil.tip.crop.circle"
        case .tools: return "square.grid.2x2"
        case .open: return "folder"
        case .save: return "square.and.arrow.down"
        case .close: return "xmark.circle"
        case .export: return "square.and.arrow.up"
        case .ocr: return "text.viewfinder"
        case .signature: return "signature"
        case .print: return "printer"
        }
    }
    var isNewFile: Bool { [.newPDF, .newMarkdown, .newText, .newHTML].contains(self) }
    var pinned: Bool { self == .annotate || self == .tools }
}

struct ToolbarPreferences: Codable, Equatable {
    static let key = "KongFolio.toolbarPreferences"
    var order = ToolbarAction.allCases
    var hidden: Set<ToolbarAction> = [.ocr, .signature, .print]
    var iconsOnly = false
    static func decode(_ text: String) -> Self {
        var value = (try? JSONDecoder().decode(Self.self, from: Data(text.utf8))) ?? Self()
        var seen = Set<ToolbarAction>()
        value.order = (value.order + ToolbarAction.allCases).filter { seen.insert($0).inserted }
        value.hidden = value.hidden.filter { !$0.pinned }
        return value
    }
    var encoded: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }
    var visible: [ToolbarAction] { order.filter { !hidden.contains($0) || $0.pinned } }
    mutating func move(_ action: ToolbarAction, by delta: Int) {
        guard let index = order.firstIndex(of: action), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
    }
}
