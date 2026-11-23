import AppKit
import SwiftUI

struct AnnotationToolsAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    func annotationToolsAnchor(when isAnchor: Bool = true) -> some View {
        anchorPreference(key: AnnotationToolsAnchor.self, value: .bounds) { isAnchor ? $0 : nil }
    }

    func excerptToolsAnchor(when isAnchor: Bool = true) -> some View {
        anchorPreference(key: ExcerptToolsAnchor.self, value: .bounds) { isAnchor ? $0 : nil }
    }
}

struct ExcerptToolsAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

private struct AnchoredPDFTools<Content: View>: View {
    let anchor: Anchor<CGRect>
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let button = geometry[anchor]
            let margin: CGFloat = 8
            let left = max(margin, min(button.midX - width / 2, geometry.size.width - width - margin))
            content()
                .fixedSize()
                .offset(x: left, y: button.maxY + margin)
        }
    }
}

struct AnchoredAnnotationTools: View {
    @ObservedObject var workspace: Workspace
    let anchor: Anchor<CGRect>?

    var body: some View {
        if let anchor, workspace.showsQuickAnnotationTools, workspace.count > 0,
           !workspace.showsPageThumbnails, !workspace.readingLocked, !workspace.busy {
            AnchoredPDFTools(anchor: anchor, width: QuickAnnotationTools.width) {
                QuickAnnotationTools(workspace: workspace)
            }
        }
    }
}

struct AnchoredExcerptTools: View {
    @ObservedObject var workspace: Workspace
    let anchor: Anchor<CGRect>?
    @Environment(\.colorScheme) private var colorScheme
    private static let buttonWidth: CGFloat = 96
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 5

    var body: some View {
        if let anchor, workspace.showsPDFExcerptTools, workspace.canQuickPDFExcerpt, !workspace.showsPageThumbnails {
            AnchoredPDFTools(anchor: anchor, width: Self.buttonWidth * 2 + Self.spacing + Self.padding * 2) {
                HStack(spacing: Self.spacing) {
                    button("摘录文字", symbol: "text.quote", selected: workspace.awaitsPDFExcerptText) {
                        workspace.choosePDFTextExcerpt()
                    }
                    button("摘录图片", symbol: "viewfinder", selected: workspace.tool == .region && workspace.previewsPDFImageExcerpt) {
                        workspace.choosePDFImageExcerpt()
                    }
                }
                .environment(\.toolbarIconTone, PDFToolbarPalette.graphite(colorScheme))
                .padding(Self.padding)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                .accessibilityIdentifier("quickExcerptTools")
            }
        }
    }

    private func button(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, appIcon: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: Self.buttonWidth, height: 36)
                .background(selected ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct QuickAnnotationTools: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.colorScheme) private var colorScheme
    private static let buttonWidth: CGFloat = 44
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 5
    static var width: CGFloat { buttonWidth * 2 + spacing + padding * 2 }

    var body: some View {
        HStack(spacing: Self.spacing) {
            button("马克笔", symbol: "highlighter", selected: workspace.tool == .pen && !workspace.penHighlighter) {
                workspace.openMarkerSettings()
            }
            button("橡皮擦", symbol: "eraser", selected: workspace.tool == .eraser) {
                workspace.selectTool(.eraser)
            }
        }
        .environment(\.toolbarIconTone, PDFToolbarPalette.graphite(colorScheme))
        .padding(Self.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
        .accessibilityIdentifier("quickAnnotationTools")
        .disabled(workspace.readingLocked)
    }

    private func button(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppIcon(symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: Self.buttonWidth, height: 36)
                .background(selected ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct MarkerSettingsPanel: View {
    @ObservedObject var workspace: Workspace

    private let swatches: [(String, Color)] = [
        ("红色", .red), ("黑色", .black), ("绿色", .green), ("橙色", .orange), ("紫色", .purple)
    ]

    private var width: Binding<Double> {
        Binding(get: { workspace.drawingStrokeStyle.width }, set: { workspace.penWidth = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("笔类工具").font(.headline)
                Spacer()
                Button { workspace.showPenSettings = false } label: {
                    AppIcon("xmark").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("关闭笔类工具面板")
                .accessibilityLabel("关闭笔类工具面板")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("线条宽度").font(.subheadline.weight(.medium))
                        HStack {
                            Slider(value: width, in: 0.5...24, step: 0.1) { Text("线条宽度") }.labelsHidden()
                            Menu {
                                ForEach([0.5, 1, 2, 4.3, 6, 8, 12, 18, 24], id: \.self) { value in
                                    Button("\(value, format: .number.precision(.fractionLength(0...1))) pt") { width.wrappedValue = value }
                                }
                            } label: {
                                Text("\(width.wrappedValue, format: .number.precision(.fractionLength(0...1))) pt")
                                    .monospacedDigit()
                            }
                            .fixedSize()
                            .accessibilityLabel("线宽预设")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("笔触灵敏度").font(.subheadline.weight(.medium))
                        HStack(spacing: 8) {
                            touchButton(.direct, symbol: "waveform.path")
                            touchButton(.smooth, symbol: "waveform.path.ecg")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("不透明度").font(.subheadline.weight(.medium))
                        HStack {
                            Slider(value: $workspace.markerOpacity, in: 0.05...1, step: 0.01) { Text("不透明度") }.labelsHidden()
                            Menu {
                                ForEach([10, 25, 50, 75, 100], id: \.self) { value in
                                    Button("\(value)%") { workspace.markerOpacity = Double(value) / 100 }
                                }
                            } label: {
                                Text(workspace.markerOpacity, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                            .fixedSize()
                            .accessibilityLabel("不透明度预设")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("颜色").font(.subheadline.weight(.medium))
                        HStack(spacing: 4) {
                            ForEach(swatches, id: \.0) { swatch in
                                swatchButton(swatch.0, color: swatch.1)
                            }
                            Spacer(minLength: 0)
                            ColorPicker("自定义笔迹颜色", selection: $workspace.annotationColor, supportsOpacity: false)
                                .labelsHidden()
                                .help("自定义笔迹颜色")
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Brand.accent)
        .accessibilityIdentifier("markerSettingsPanel")
    }

    private var preview: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            let samples = (0...32).map { index -> CGPoint in
                let progress = Double(index) / 32
                return CGPoint(x: w * (0.12 + progress * 0.76), y: h * (0.5 - 0.24 * sin(progress * 2 * .pi)))
            }
            let points = workspace.markerTouch.strokePoints(samples)
            Path { path in
                path.move(to: points[0])
                path.addLines(Array(points.dropFirst()))
            }
            .stroke(workspace.annotationColor.opacity(workspace.markerOpacity),
                    style: StrokeStyle(lineWidth: width.wrappedValue, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 116)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary).allowsHitTesting(false) }
        .accessibilityLabel("笔迹预览")
    }

    private func touchButton(_ touch: MarkerTouch, symbol: String) -> some View {
        let selected = workspace.markerTouch == touch
        return Button { workspace.markerTouch = touch } label: {
            Label(touch.title, appIcon: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Brand.accent.opacity(0.13) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Brand.accent : Color.primary.opacity(0.14))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(touch == .direct ? "跟随鼠标原始轨迹" : "减少鼠标拐角处的抖动")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func swatchButton(_ title: String, color: Color) -> some View {
        let selected = NSColor(workspace.annotationColor).usingColorSpace(.sRGB) ==
            NSColor(color).usingColorSpace(.sRGB)
        return Button { workspace.chooseAnnotationColor(color) } label: {
            Circle().fill(color)
                .frame(width: 21, height: 21)
                .padding(4)
                .background(selected ? Brand.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Brand.accent : .clear) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
