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
    var position: CGPoint?
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

final class PDFCommentDragHandle: NSView {
    enum Operation { case move, resize }

    private let operation: Operation
    private var start: (location: CGPoint, frame: CGRect)?
    var onDrag: ((Operation, CGRect, CGPoint) -> Void)?

    init(_ operation: Operation) {
        self.operation = operation
        super.init(frame: .zero)
        toolTip = operation == .move ? "拖动以移动评论" : "拖动以调整评论大小"
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: operation == .move ? .openHand : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.secondaryLabelColor.setStroke()
        let grip = NSBezierPath()
        grip.lineWidth = 1.25
        switch operation {
        case .move:
            for offset in [-2.0, 2.0] as [CGFloat] {
                grip.move(to: CGPoint(x: bounds.midX - 11, y: bounds.midY + offset))
                grip.line(to: CGPoint(x: bounds.midX + 11, y: bounds.midY + offset))
            }
        case .resize:
            for inset in [4.0, 8.0, 12.0] as [CGFloat] {
                grip.move(to: CGPoint(x: bounds.maxX - inset, y: bounds.minY + 3))
                grip.line(to: CGPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
            }
        }
        grip.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor = superview, let canvas = editor.superview else { return }
        start = (canvas.convert(event.locationInWindow, from: nil), editor.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let canvas = superview?.superview else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        onDrag?(operation, start.frame, CGPoint(x: point.x - start.location.x, y: point.y - start.location.y))
    }

    override func mouseUp(with event: NSEvent) { start = nil }
}

final class PDFInlineCommentInput: NSView, NSTextViewDelegate {
    let draft: PDFCommentDraft
    let textView = PDFCommentTextView(frame: CGRect(x: 0, y: 0, width: 220, height: 64))
    var onTextChange: (() -> Void)?
    let moveHandle = PDFCommentDragHandle(.move)
    let resizeHandle = PDFCommentDragHandle(.resize)
    private let scroll = NSScrollView()
    private var appliedStyle: PDFCommentStyle?
    var content: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(draft: PDFCommentDraft) {
        self.draft = draft
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.setAccessibilityLabel("评论内容")
        textView.string = draft.existing?.contents ?? ""
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.delegate = self
        scroll.documentView = textView
        addSubview(scroll)
        if draft.supportsStyle {
            addSubview(moveHandle)
            addSubview(resizeHandle)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let area = bounds.insetBy(dx: 1, dy: 1)
        guard draft.supportsStyle else { scroll.frame = area; return }
        let top: CGFloat = 16
        let bottom: CGFloat = 16
        moveHandle.frame = CGRect(x: area.minX, y: area.maxY - top, width: area.width, height: top)
        resizeHandle.frame = CGRect(x: area.maxX - 18, y: area.minY, width: 18, height: bottom)
        scroll.frame = CGRect(x: area.minX, y: area.minY + bottom, width: area.width,
                              height: max(0, area.height - top - bottom))
    }

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
        layer?.backgroundColor = background.cgColor
        scroll.backgroundColor = background
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
                        Text("拖动评论框顶部可移动，拖动右下角可调整大小。").foregroundStyle(.secondary)
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
