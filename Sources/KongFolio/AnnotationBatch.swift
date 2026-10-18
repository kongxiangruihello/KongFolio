import AppKit
import PDFKit
import SwiftUI

enum AnnotationRecolor {
    /// Gives the annotation `color`, keeping what is see-through about it (a highlighter stroke, a marker).
    static func apply(_ annotation: PDFAnnotation, color: NSColor) {
        switch annotation.type ?? "" {
        case "FreeText": annotation.fontColor = color
        case "Highlight": annotation.color = color.withAlphaComponent(0.4)
        default:
            let alpha = annotation.color.alphaComponent
            annotation.color = color.withAlphaComponent(alpha < 1 ? alpha : 1)
        }
    }
}

extension Workspace {
    /// The annotations behind the ticked entries of the list (resolved by page and position, as `goToNote` does).
    func annotations(ofNotes ids: Set<String>) -> [PDFAnnotation] {
        annotationNotes.filter { ids.contains($0.id) }.compactMap { note in
            guard let page = document.page(at: note.page), note.index < page.annotations.count else { return nil }
            return page.annotations[note.index]
        }
    }

    func toggleNote(_ id: String) {
        if selectedNoteIDs.contains(id) { selectedNoteIDs.remove(id) } else { selectedNoteIDs.insert(id) }
    }

    /// Ticks everything the list shows (so a filter plus "select all" picks one kind, one colour or one search result).
    func selectNotes(_ shown: [AnnotationNote]) { selectedNoteIDs = Set(shown.map(\.id)) }

    func deleteSelectedNotes() {
        let targets = annotations(ofNotes: selectedNoteIDs)
        guard !targets.isEmpty else { return }
        let edits = beginAnnotationEdit(targets)
        for annotation in targets { annotation.page?.removeAnnotation(annotation) }
        selectedAnnotation = nil
        selectedNoteIDs = []
        commitAnnotationEdit(edits)
        status = "已删除 \(targets.count) 个标注（可撤销）"
    }

    func recolorSelectedNotes(_ color: NSColor) {
        let targets = annotations(ofNotes: selectedNoteIDs)
        guard !targets.isEmpty else { return }
        let edits = beginAnnotationEdit(targets)
        for annotation in targets { AnnotationRecolor.apply(annotation, color: color) }
        commitAnnotationEdit(edits)
        status = "已改色 \(targets.count) 个标注（可撤销）"
    }

    // MARK: Presets

    var allPresets: [AnnotationPreset] { AnnotationPresets.builtIn + userPresets }

    func apply(_ preset: AnnotationPreset) {
        if preset.highlighter { selectTool(.pen, highlighter: true) } else if tool == .pen { selectTool(.pen) }
        annotationColor = Color(.sRGB, red: preset.rgb[0], green: preset.rgb[1], blue: preset.rgb[2], opacity: 1)
        penWidth = preset.width
        lineDashed = preset.dashed
        shapeFill = preset.fill
        status = "已套用样式“\(preset.name)”"
    }

    func currentStylePreset(named name: String) -> AnnotationPreset {
        let rgb = NSColor(annotationColor).usingColorSpace(.sRGB)
        return AnnotationPreset(name: AnnotationPresets.freshName(name, among: userPresets),
                                rgb: [Double(rgb?.redComponent ?? 0), Double(rgb?.greenComponent ?? 0), Double(rgb?.blueComponent ?? 0)],
                                width: penWidth, dashed: lineDashed, fill: shapeFill, highlighter: penHighlighter && tool == .pen)
    }

    func saveCurrentStyle(named name: String) {
        let preset = currentStylePreset(named: name)
        userPresets.append(preset)
        status = "已保存样式“\(preset.name)”"
    }

    func deletePreset(_ preset: AnnotationPreset) { userPresets.removeAll { $0.id == preset.id } }
}
