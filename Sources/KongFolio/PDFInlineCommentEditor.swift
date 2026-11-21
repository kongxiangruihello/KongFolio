import SwiftUI

struct PDFInlineCommentEditor: View {
    @State var text: String
    @State var style: PDFCommentStyle
    let editing: Bool
    let supportsStyle: Bool
    let save: (String, PDFCommentStyle) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var previewFont: Font {
        let design: Font.Design
        switch style.typeface {
        case .system: design = .default
        case .serif: design = .serif
        case .monospaced: design = .monospaced
        }
        let font = Font.system(size: CGFloat(style.fontSize), weight: style.bold ? .bold : .regular, design: design)
        return style.italic ? font.italic() : font
    }

    private var alignment: TextAlignment {
        switch style.alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(editing ? "编辑评论" : "添加评论", systemImage: "text.bubble")
                .font(.headline)
            if supportsStyle { typography }
            TextEditor(text: $text)
                .font(previewFont)
                .foregroundStyle(Color(nsColor: style.ink))
                .multilineTextAlignment(alignment)
                .scrollContentBackground(.hidden)
                .frame(height: 128)
                .padding(5)
                .background(style.transparent ? Color.white : Color(nsColor: style.fill),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.4),
                                      style: StrokeStyle(lineWidth: style.frame == .none ? 0.5 : 1,
                                                         dash: style.frame == .dashed ? [4, 3] : []))
                        .allowsHitTesting(false)
                }
                .focused($focused)
                .accessibilityLabel("评论内容")
            if supportsStyle { cardOptions }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存") { save(trimmedText, style) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(14)
        .frame(width: supportsStyle ? 398 : 300)
        .task { focused = true }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("字体", selection: $style.typeface) {
                    ForEach(PDFCommentStyle.Typeface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("\(style.fontSize) pt", value: $style.fontSize, in: 8...72)
                    .fixedSize()
                    .accessibilityLabel("字号")
                Toggle(isOn: $style.bold) { Image(systemName: "bold") }
                    .toggleStyle(.button)
                    .help("粗体")
                    .accessibilityLabel("粗体")
                Toggle(isOn: $style.italic) { Image(systemName: "italic") }
                    .toggleStyle(.button)
                    .help("斜体")
                    .accessibilityLabel("斜体")
            }
            HStack {
                Picker("对齐", selection: $style.alignment) {
                    ForEach(PDFCommentStyle.Alignment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                ColorPicker("字色", selection: colorBinding($style.textColor), supportsOpacity: false)
                    .fixedSize()
            }
        }
    }

    private var cardOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("边框", selection: $style.frame) {
                    ForEach(PDFCommentStyle.Frame.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                ColorPicker("底色", selection: colorBinding($style.backgroundColor), supportsOpacity: false)
                    .disabled(style.transparent)
                    .fixedSize()
                Toggle("透明", isOn: $style.transparent).fixedSize()
            }
            HStack {
                Stepper("宽 \(style.width) pt", value: $style.width, in: 80...1200, step: 10)
                    .fixedSize()
                    .accessibilityLabel("评论框宽度")
                Stepper("高 \(style.height) pt", value: $style.height, in: 28...1200, step: 10)
                    .disabled(style.automaticHeight)
                    .fixedSize()
                    .accessibilityLabel("评论框高度")
                Spacer(minLength: 4)
                Toggle("自动高度", isOn: $style.automaticHeight).fixedSize()
            }
        }
    }

    private func colorBinding(_ value: Binding<UInt32>) -> Binding<Color> {
        Binding(get: { Color(nsColor: PDFCommentStyle.color(value.wrappedValue)) },
                set: { if let color = PDFCommentStyle.rgb(NSColor($0)) { value.wrappedValue = color } })
    }
}
