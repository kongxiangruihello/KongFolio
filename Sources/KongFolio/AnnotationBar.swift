import AppKit
import PDFKit
import SwiftUI

/// The drawing tools within reach of the page, so lines and marks do not depend on the side panel.
struct AnnotationBar: View {
    @ObservedObject var workspace: Workspace
    var availableWidth: CGFloat = 900

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
        bar
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

    private var presetsMenu: some View {
        Menu {
            ForEach(workspace.allPresets) { preset in
                Button(preset.name) { workspace.apply(preset) }
            }
            Divider()
            Button("把当前样式存为预设…") {
                if let name = Self.askName() { workspace.saveCurrentStyle(named: name) }
            }
            if !workspace.userPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(workspace.userPresets) { preset in
                        Button(preset.name) { workspace.deletePreset(preset) }
                    }
                }
            }
        } label: { Image(systemName: "star.square") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34).hint("样式预设：颜色、线宽、虚线、填充一键套用", $hovered)
    }

    private var textBoxMenu: some View {
        Menu {
            Menu("字体") {
                ForEach(AnnotationTextStyle.fonts, id: \.title) { item in Button(item.title) { workspace.styleTextBoxes(font: item.name) } }
            }
            Menu("字号") {
                ForEach(AnnotationTextStyle.sizes, id: \.self) { size in Button("\(Int(size)) 磅") { workspace.styleTextBoxes(size: size) } }
            }
            Menu("底色") {
                ForEach(AnnotationTextStyle.fills, id: \.title) { item in Button(item.title) { workspace.styleTextBoxes(fill: item.color) } }
            }
            Menu("边框") {
                Button("无") { workspace.styleTextBoxes(border: 0) }
                Button("细（1 磅）") { workspace.styleTextBoxes(border: 1) }
                Button("粗（2 磅）") { workspace.styleTextBoxes(border: 2) }
            }
        } label: { Image(systemName: "textformat.size") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34).hint("文字框样式：先用“编辑标注”点选一个文字框，或在标注列表里勾选", $hovered)
    }

    private var layersMenu: some View {
        Menu {
            ForEach(AnnotationFilter.kinds, id: \.self) { kind in
                Button { workspace.setLayer(kind, visible: workspace.hiddenKinds.contains(kind)) } label: {
                    Text((workspace.hiddenKinds.contains(kind) ? "显示 " : "隐藏 ") + kind)
                }
            }
            Divider()
            Button("全部显示") { workspace.showAllLayers() }.disabled(workspace.hiddenKinds.isEmpty)
        } label: { Image(systemName: workspace.hiddenKinds.isEmpty ? "square.3.layers.3d" : "square.3.layers.3d.slash") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34).hint("按类型隐藏或显示标注（只影响显示，保存和导出时一律完整）", $hovered)
    }

    private static func askName() -> String? {
        let alert = NSAlert()
        alert.messageText = "预设名称"
        alert.informativeText = "保存当前的颜色、线宽、虚线与填充设置。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "我的样式"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private var bar: some View {
        Group {
            if availableWidth >= 900 { HStack(spacing: 6) { controls } }
            else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 6)], spacing: 8) { controls } }
        }
        .frame(width: max(120, availableWidth - 20))

        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }

    @ViewBuilder private var controls: some View {
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
            ColorPicker("", selection: Binding(get: { workspace.annotationColor }, set: { workspace.chooseAnnotationColor($0) }), supportsOpacity: false).labelsHidden().frame(width: 28).clipped()
                .hint("更多颜色…", $hovered)
            presetsMenu
            textBoxMenu
            layersMenu
            Menu {
                ForEach([1.0, 2.0, 3.0, 5.0, 8.0], id: \.self) { width in
                    Button("\(Int(width)) 磅") { workspace.penWidth = width }
                }
            } label: { Image(systemName: "lineweight") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34).hint(String(format: "线宽（现在 %.1f 磅）", workspace.penWidth), $hovered)
            Toggle(isOn: $workspace.shapeFill) { Image(systemName: "square.fill") }
                .toggleStyle(.button).buttonStyle(.plain).hint("矩形、椭圆填充半透明颜色", $hovered)
            Toggle(isOn: $workspace.lineDashed) { Image(systemName: "line.3.horizontal") }
                .toggleStyle(.button).buttonStyle(.plain).hint("虚线（直线、箭头、矩形、椭圆）", $hovered)
            Divider().frame(height: 20)
            Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(!workspace.canUndo).hint("撤销（⌘Z）", $hovered)
            Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.plain).disabled(!workspace.canRedo).hint("重做（⇧⌘Z）", $hovered)
            Button { workspace.showAnnotationBar = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).hint("收起工具栏，回到阅读", $hovered)
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

    }
}

private extension View {
    func hint(_ text: String, _ current: Binding<String?>) -> some View { modifier(HintModifier(text: text, current: current)) }
}
