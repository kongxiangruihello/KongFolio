import AppKit
import SwiftUI

struct SavedDrawingStyle: Codable, Equatable {
    var rgb: [Double]
    var width: Double
    var dashed: Bool
    var fill: Bool
    static let key = "KongFolio.drawingStyles.v1"
    static func load(_ defaults: UserDefaults) -> [String: SavedDrawingStyle] {
        guard let data = defaults.data(forKey: key), let styles = try? JSONDecoder().decode([String: SavedDrawingStyle].self, from: data) else { return [:] }
        return styles.filter { _, s in s.rgb.count == 3 && s.rgb.allSatisfy { $0.isFinite && (0...1).contains($0) } && s.width.isFinite && (0.1...100).contains(s.width) }
    }
}

extension Workspace {
    func loadDrawingStyles() {
        toolStyles = SavedDrawingStyle.load(drawingDefaults)
        drawingStylesReady = true
        let raw = drawingDefaults.string(forKey: "KongFolio.lastDrawingTool")
        let next = raw.flatMap(AnnotationTool.init(rawValue:)) ?? .pen
        selectTool(next, highlighter: drawingDefaults.bool(forKey: "KongFolio.lastHighlighter"))
        if !showAnnotationBar { tool = .select }
    }
    func rememberDrawingStyle() {
        guard drawingStylesReady, !restoringDrawingStyle else { return }
        let key = AnnotationStyleDefaults.key(tool: tool, highlighter: penHighlighter)
        guard AnnotationStyleDefaults.style(for: key) != nil,
              let rgb = NSColor(annotationColor).usingColorSpace(.sRGB) else { return }
        let style = SavedDrawingStyle(rgb: [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], width: penWidth, dashed: lineDashed, fill: shapeFill)
        var styles = SavedDrawingStyle.load(drawingDefaults)
        styles[key] = style
        toolStyles = styles
        if let data = try? JSONEncoder().encode(styles) { drawingDefaults.set(data, forKey: SavedDrawingStyle.key) }
        drawingDefaults.set(tool.rawValue, forKey: "KongFolio.lastDrawingTool")
        drawingDefaults.set(penHighlighter, forKey: "KongFolio.lastHighlighter")
    }
}
