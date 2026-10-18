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
        Entry(id: "select", tool: .select, highlighter: false, symbol: "cursorarrow", help: "选择 / 阅读（快捷键 V）"),
        Entry(id: "pen", tool: .pen, highlighter: false, symbol: "pencil.tip", help: "画笔：自由画线（快捷键 P）"),
        Entry(id: "marker", tool: .pen, highlighter: true, symbol: "highlighter", help: "荧光笔：宽而半透明的线（快捷键 H）"),
        Entry(id: "line", tool: .line, highlighter: false, symbol: "line.diagonal", help: "直线（按住 Shift 取 15° 的倍数）（快捷键 L）"),
        Entry(id: "arrow", tool: .arrow, highlighter: false, symbol: "arrow.up.right", help: "箭头（快捷键 A）"),
        Entry(id: "rectangle", tool: .rectangle, highlighter: false, symbol: "rectangle", help: "矩形（按住 Shift 画正方形）（快捷键 R）"),
        Entry(id: "ellipse", tool: .ellipse, highlighter: false, symbol: "circle", help: "椭圆（按住 Shift 画圆）（快捷键 O）"),
        Entry(id: "text", tool: .textBox, highlighter: false, symbol: "textformat", help: "文字框：点一下页面，输入文字（快捷键 T）"),
        Entry(id: "note", tool: .note, highlighter: false, symbol: "note.text", help: "批注图标：点一下页面，输入文字（快捷键 N）"),
        Entry(id: "edit", tool: .edit, highlighter: false, symbol: "pencil.and.outline", help: "编辑标注：点选后拖动、点颜色改色、按 Delete 删除（快捷键 E）"),
        Entry(id: "eraser", tool: .eraser, highlighter: false, symbol: "eraser", help: "橡皮：点一下标注就删除（可撤销）（快捷键 X）"),
    ]
    private let swatches: [(name: String, color: Color)] = [("红", .red), ("橙", .orange), ("黄", .yellow), ("绿", .green), ("蓝", .blue), ("黑", .black)]

    private func active(_ entry: Entry) -> Bool {
        guard workspace.tool == entry.tool else { return false }
        return entry.tool != .pen || workspace.penHighlighter == entry.highlighter
    }

    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 6) { bar; caption }
    }

    /// The name of whatever the pointer is over, shown at once (the system tooltip waits a second or more).
    @ViewBuilder private var caption: some View {
        if let hovered {
            Text(hovered).font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .transition(.opacity)
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            ForEach(entries) { entry in
                Button {
                    workspace.selectTool(entry.tool, highlighter: entry.highlighter)
                } label: {
                    Image(systemName: entry.symbol).frame(width: 26, height: 24)
                        .background(active(entry) ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hint(entry.help, $hovered)
            }
            Divider().frame(height: 20)
            ForEach(swatches, id: \.name) { swatch in
                Button { workspace.chooseAnnotationColor(swatch.color) } label: {
                    Circle().fill(swatch.color).frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.primary, lineWidth: workspace.annotationColor == swatch.color ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
                .hint("颜色：\(swatch.name)", $hovered)
            }
            ColorPicker("", selection: Binding(get: { workspace.annotationColor }, set: { workspace.chooseAnnotationColor($0) }), supportsOpacity: false).labelsHidden().frame(width: 28)
                .hint("更多颜色…", $hovered)
            Menu {
                ForEach([1.0, 2.0, 3.0, 5.0, 8.0], id: \.self) { width in
                    Button("\(Int(width)) 磅") { workspace.penWidth = width }
                }
            } label: { Image(systemName: "lineweight") }
                .menuStyle(.borderlessButton).frame(width: 34).hint("线宽（现在 \(workspace.penWidth, format: .number.precision(.fractionLength(1))) 磅）", $hovered)
            Toggle(isOn: $workspace.shapeFill) { Image(systemName: "square.fill") }
                .toggleStyle(.button).buttonStyle(.plain).hint("矩形、椭圆填充半透明颜色", $hovered)
            Toggle(isOn: $workspace.lineDashed) { Image(systemName: "line.3.horizontal") }
                .toggleStyle(.button).buttonStyle(.plain).hint("虚线（直线、箭头、矩形、椭圆）", $hovered)
            Divider().frame(height: 20)
            Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(!workspace.canUndo).hint("撤销（⌘Z）", $hovered)
            Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.plain).disabled(!workspace.canRedo).hint("重做（⇧⌘Z）", $hovered)
            Button { workspace.showAnnotationBar = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).hint("收起工具栏，回到阅读", $hovered)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}

/// The small button that opens the annotation bar while it is closed.
struct AnnotationBarButton: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button { workspace.showAnnotationBar = true } label: {
            Label("标注", systemImage: "pencil.tip.crop.circle").font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("打开标注工具栏（⌥⌘A）：画线、画框、写文字、荧光笔")
    }
}

/// A Chinese tooltip that also shows in the bar's caption line right away; the whole box counts as hoverable, not just the glyph.
private struct HintModifier: ViewModifier {
    let text: String
    @Binding var current: String?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .help(text)
            .onHover { inside in
                if inside { current = text } else if current == text { current = nil }
            }
    }
}

private extension View {
    func hint(_ text: String, _ current: Binding<String?>) -> some View { modifier(HintModifier(text: text, current: current)) }
}
