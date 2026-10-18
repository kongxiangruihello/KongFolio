import AppKit
import PDFKit
import SwiftUI

/// The drawing tools within reach of the page, so lines and marks do not depend on the side panel.
struct AnnotationBar: View {
    @ObservedObject var workspace: Workspace

    private struct Entry: Identifiable {
        let id: String
        let tool: AnnotationTool
        let highlighter: Bool
        let symbol: String
        let help: String
    }

    private let entries: [Entry] = [
        Entry(id: "select", tool: .select, highlighter: false, symbol: "cursorarrow", help: "选择 / 阅读"),
        Entry(id: "pen", tool: .pen, highlighter: false, symbol: "pencil.tip", help: "画笔：自由画线"),
        Entry(id: "marker", tool: .pen, highlighter: true, symbol: "highlighter", help: "荧光笔：宽而半透明的线"),
        Entry(id: "line", tool: .line, highlighter: false, symbol: "line.diagonal", help: "直线（按住 Shift 取 15° 的倍数）"),
        Entry(id: "arrow", tool: .arrow, highlighter: false, symbol: "arrow.up.right", help: "箭头"),
        Entry(id: "rectangle", tool: .rectangle, highlighter: false, symbol: "rectangle", help: "矩形（按住 Shift 画正方形）"),
        Entry(id: "ellipse", tool: .ellipse, highlighter: false, symbol: "circle", help: "椭圆（按住 Shift 画圆）"),
        Entry(id: "text", tool: .textBox, highlighter: false, symbol: "textformat", help: "文字框：点一下页面，输入文字"),
        Entry(id: "note", tool: .note, highlighter: false, symbol: "note.text", help: "批注图标：点一下页面，输入文字"),
        Entry(id: "edit", tool: .edit, highlighter: false, symbol: "pencil.and.outline", help: "编辑标注：点选后拖动、改色、删除"),
    ]
    private let swatches: [(name: String, color: Color)] = [("红", .red), ("橙", .orange), ("黄", .yellow), ("绿", .green), ("蓝", .blue), ("黑", .black)]

    private func active(_ entry: Entry) -> Bool {
        guard workspace.tool == entry.tool else { return false }
        return entry.tool != .pen || workspace.penHighlighter == entry.highlighter
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(entries) { entry in
                Button {
                    workspace.tool = entry.tool
                    if entry.tool == .pen { workspace.penHighlighter = entry.highlighter }
                } label: {
                    Image(systemName: entry.symbol).frame(width: 26, height: 24)
                        .background(active(entry) ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(entry.help)
            }
            Divider().frame(height: 20)
            ForEach(swatches, id: \.name) { swatch in
                Button { workspace.annotationColor = swatch.color } label: {
                    Circle().fill(swatch.color).frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.primary, lineWidth: workspace.annotationColor == swatch.color ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }
            ColorPicker("", selection: $workspace.annotationColor, supportsOpacity: false).labelsHidden().frame(width: 28)
            Menu {
                ForEach([1.0, 2.0, 3.0, 5.0, 8.0], id: \.self) { width in
                    Button("\(Int(width)) 磅") { workspace.penWidth = width }
                }
            } label: { Image(systemName: "lineweight") }
                .menuStyle(.borderlessButton).frame(width: 34).help("线宽（现在 \(workspace.penWidth, format: .number.precision(.fractionLength(1))) 磅）")
            Toggle(isOn: $workspace.shapeFill) { Image(systemName: "square.fill") }
                .toggleStyle(.button).buttonStyle(.plain).help("矩形、椭圆填充半透明颜色")
            Divider().frame(height: 20)
            Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(!workspace.canUndo).help("撤销")
            Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.plain).disabled(!workspace.canRedo).help("重做")
            Button { workspace.showAnnotationBar = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起工具栏（标注菜单里可以再打开）")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}
