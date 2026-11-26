import AppKit
import PDFKit
import SwiftUI

@MainActor final class PDFCommentDraft: ObservableObject {
    let page: PDFPage
    let anchor: CGRect
    let quote: String?
    let existing: PDFAnnotation?
    let highlight: PDFSelection?
    let supportsStyle: Bool
    @Published var style: PDFCommentStyle
    @Published var hasText: Bool

    init(page: PDFPage, anchor: CGRect, quote: String?, existing: PDFAnnotation?, highlight: PDFSelection?) {
        self.page = page
        self.anchor = anchor
        self.quote = quote
        self.existing = existing
        self.highlight = highlight
        supportsStyle = existing.map(PDFInlineComment.isCard) ?? true
        style = existing.map(PDFInlineComment.style(of:)) ?? PDFCommentStyle()
        hasText = !(existing?.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class PDFCommentTextView: NSTextView {
    var save: (() -> Void)?
    var cancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 53 {
                cancel?()
                return
            }
            if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
                save?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class PDFInlineCommentInput: NSScrollView, NSTextViewDelegate {
    let draft: PDFCommentDraft
    let textView = PDFCommentTextView(frame: CGRect(x: 0, y: 0, width: 220, height: 64))
    var onTextChange: (() -> Void)?
    private var appliedStyle: PDFCommentStyle?
    var content: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(draft: PDFCommentDraft) {
        self.draft = draft
        super.init(frame: .zero)
        borderType = .lineBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 220, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.setAccessibilityLabel("评论内容")
        textView.string = draft.existing?.contents ?? ""
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.delegate = self
        documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    func textDidChange(_ notification: Notification) {
        let hasText = !content.isEmpty
        if draft.hasText != hasText { draft.hasText = hasText }
        if !textView.hasMarkedText() { onTextChange?() }
    }

    func applyStyle(_ style: PDFCommentStyle, scale: CGFloat) {
        var visualStyle = style
        visualStyle.fontSize = Int(min(max(CGFloat(visualStyle.fontSize) * scale, 9), 220).rounded())
        guard visualStyle != appliedStyle else { return }
        appliedStyle = visualStyle
        textView.font = visualStyle.font
        textView.alignment = visualStyle.alignment.native
        textView.textColor = visualStyle.ink
        textView.insertionPointColor = visualStyle.ink
        let background: NSColor = visualStyle.transparent ? .white : visualStyle.fill
        backgroundColor = background
        textView.backgroundColor = background
    }
}

struct PDFCommentOptions: View {
    @ObservedObject var draft: PDFCommentDraft
    let save: () -> Void
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("评论选项", appIcon: "text.bubble").font(.headline)
                Spacer()
                SidePanelCloseButton(title: "关闭评论选项", close: close)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("在 PDF 页面上输入评论").foregroundStyle(.secondary)
                    if draft.supportsStyle {
                        typography
                        cardOptions
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", action: cancel)
                Button("保存评论", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasText)
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("字体", selection: $draft.style.typeface) {
                ForEach(PDFCommentStyle.Typeface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Stepper("\(draft.style.fontSize) pt", value: $draft.style.fontSize, in: 8...72)
                    .accessibilityLabel("字号")
                Toggle(isOn: $draft.style.bold) { AppIcon("bold") }
                    .toggleStyle(.button).help("粗体").accessibilityLabel("粗体")
                Toggle(isOn: $draft.style.italic) { AppIcon("italic") }
                    .toggleStyle(.button).help("斜体").accessibilityLabel("斜体")
            }
            Picker("对齐", selection: $draft.style.alignment) {
                ForEach(PDFCommentStyle.Alignment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            ColorPicker("字色", selection: colorBinding($draft.style.textColor), supportsOpacity: false)
        }
    }

    private var cardOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("边框", selection: $draft.style.frame) {
                ForEach(PDFCommentStyle.Frame.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                ColorPicker("底色", selection: colorBinding($draft.style.backgroundColor), supportsOpacity: false)
                    .disabled(draft.style.transparent)
                Toggle("透明", isOn: $draft.style.transparent)
            }
            Stepper("宽 \(draft.style.width) pt", value: $draft.style.width, in: 80...1200, step: 10)
                .accessibilityLabel("评论框宽度")
            Toggle("自动高度", isOn: $draft.style.automaticHeight)
            Stepper("高 \(draft.style.height) pt", value: $draft.style.height, in: 28...1200, step: 10)
                .disabled(draft.style.automaticHeight)
                .accessibilityLabel("评论框高度")
        }
    }

    private func colorBinding(_ value: Binding<UInt32>) -> Binding<Color> {
        Binding(get: { Color(nsColor: PDFCommentStyle.color(value.wrappedValue)) },
                set: { if let color = PDFCommentStyle.rgb(NSColor($0)) { value.wrappedValue = color } })
    }
}
