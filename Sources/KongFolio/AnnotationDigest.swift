import AppKit
import Foundation

extension MarkupColor {
    /// The marker colour an annotation colour is closest to; nil for grey, black and white.
    static func nearest(to color: NSColor) -> MarkupColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.15, brightness > 0.2 else { return nil }
        switch hue {
        case 0.08..<0.22: return .yellow
        case 0.22..<0.45: return .green
        case 0.45..<0.78: return .blue
        default: return .pink
        }
    }
}

/// Narrows the annotation list of a document (sidebar and Markdown export).
struct AnnotationFilter: Equatable {
    static let kinds = ["高亮", "下划线", "删除线", "批注", "文字框", "手写", "箭头/线条", "矩形", "椭圆"]
    static let colors = MarkupColor.allCases.map(\.rawValue)

    var kind: String? = nil
    var color: String? = nil
    var text = ""

    var isActive: Bool { kind != nil || color != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ note: AnnotationNote) -> Bool {
        if let kind, note.kind != kind { return false }
        if let color, note.colorName != color { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return note.quote.localizedCaseInsensitiveContains(needle) || note.note.localizedCaseInsensitiveContains(needle)
    }

    func apply(to notes: [AnnotationNote]) -> [AnnotationNote] { isActive ? notes.filter(matches) : notes }
}

extension Workspace {
    /// Writes the annotations (all, or those that pass `filter`) as a Markdown file.
    func exportNotes(filter: AnnotationFilter = AnnotationFilter()) {
        let notes = filter.apply(to: ReadingServices.notes(document))
        guard !notes.isEmpty else { error = "没有符合条件的标注可导出。"; return }
        guard let url = saveURL(type: .init(filenameExtension: "md") ?? .plainText, suffix: "md", name: title + "-notes") else { return }
        report {
            try ReadingServices.markdown(title: title, notes: notes, bibliography: bibliography).write(to: url, atomically: true, encoding: .utf8)
            status = "已导出 \(notes.count) 条标注（含页码和原文）"
        }
    }

    /// Opens the annotations as a new Markdown note tab, ready to edit and save.
    func openNotesAsNote(filter: AnnotationFilter = AnnotationFilter()) {
        let notes = filter.apply(to: ReadingServices.notes(document))
        guard !notes.isEmpty else { error = "没有符合条件的标注。"; return }
        guard let store else { error = "笔记标签页不可用。"; return }
        let note = store.newNote()
        note.text = ReadingServices.markdown(title: title, notes: notes, bibliography: bibliography)
        status = "已在新笔记标签页打开 \(notes.count) 条标注"
    }
}
