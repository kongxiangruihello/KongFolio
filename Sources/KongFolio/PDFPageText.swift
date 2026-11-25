import AppKit
import CoreText
import PDFKit
import SwiftUI

enum PDFPageTextColor: String, Codable, CaseIterable {
    case black = "黑色"
    case blue = "深蓝"
    case red = "深红"

    var color: NSColor {
        switch self {
        case .black: return .black
        case .blue: return NSColor(srgbRed: 0.09, green: 0.22, blue: 0.49, alpha: 1)
        case .red: return NSColor(srgbRed: 0.62, green: 0.12, blue: 0.16, alpha: 1)
        }
    }
}

/// A block located in the displayed crop box, measured in PDF points.
struct PDFPageText: Codable {
    let text: String
    let size: CGFloat
    let color: PDFPageTextColor
    let bounds: CGRect

    var isValid: Bool {
        !text.isEmpty && size.isFinite && (8...72).contains(size) &&
            [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) &&
            bounds.width > 0 && bounds.height > 0
    }

    static func layout(_ input: String, size: CGFloat, color: PDFPageTextColor,
                       at point: CGPoint, on page: PDFPage) throws -> PDFPageText {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, size.isFinite, (8...72).contains(size) else {
            throw FolioError(message: "请输入文字，并选择有效字号。")
        }
        let crop = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let display = SignatureStamp.uprightRect(CGRect(origin: .zero, size: crop.size), pageSize: crop.size, rotation: rotation)
        let anchor = displayedPoint(point, on: page)
        let inset: CGFloat = 8
        let width = min(360, display.width - inset * 2)
        let availableHeight = display.height - inset * 2
        guard width > 0, availableHeight > 0, anchor.x.isFinite, anchor.y.isFinite else {
            throw FolioError(message: "此位置无法放置文字。")
        }
        let content = attributed(text, size: size, color: color)
        let setter = CTFramesetterCreateWithAttributedString(content)
        var fitted = CFRange(location: 0, length: 0)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: availableHeight), &fitted
        )
        let height = ceil(measured.height) + 2
        guard fitted.length == CFAttributedStringGetLength(content), height <= availableHeight else {
            throw FolioError(message: "文字超出当前页，请缩短文字或减小字号后再试。")
        }
        let x = min(max(anchor.x, inset), display.width - width - inset)
        let top = min(max(anchor.y, height + inset), display.height - inset)
        let block = PDFPageText(text: text, size: size, color: color,
                                bounds: CGRect(x: x, y: top - height, width: width, height: height))
        let frame = block.frame(in: CGRect(origin: .zero, size: block.bounds.size))
        guard CTFrameGetVisibleStringRange(frame).length == fitted.length else {
            throw FolioError(message: "当前页放不下完整文字，请缩短文字后再试。")
        }
        return block
    }

    static func displayedPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        let crop = page.bounds(for: .cropBox)
        let local = CGPoint(x: point.x - crop.minX, y: point.y - crop.minY)
        return SignatureStamp.uprightRect(CGRect(origin: local, size: .zero),
                                          pageSize: crop.size, rotation: page.rotation).origin
    }

    func pageRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        return SignatureStamp.originalRect(rect, pageSize: crop.size, rotation: page.rotation)
            .offsetBy(dx: crop.minX, dy: crop.minY)
    }

    func contains(_ point: CGPoint, on page: PDFPage) -> Bool {
        let position = Self.displayedPoint(point, on: page)
        guard bounds.insetBy(dx: -3, dy: -3).contains(position) else { return false }
        let frame = frame(in: CGRect(origin: .zero, size: bounds.size))
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return false }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let origin = origins[index]
            let ink = CGRect(x: bounds.minX + origin.x, y: bounds.minY + origin.y - descent,
                             width: CGFloat(width), height: ascent + descent)
            if width > 0 && ink.insetBy(dx: -3, dy: -3).contains(position) { return true }
        }
        return false
    }

    private static func attributed(_ text: String, size: CGFloat, color: PDFPageTextColor) -> CFAttributedString {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.color.cgColor
        ]) as CFAttributedString
    }

    private func frame(in rect: CGRect) -> CTFrame {
        let setter = CTFramesetterCreateWithAttributedString(Self.attributed(text, size: size, color: color))
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    }

    func draw(in context: CGContext, originalCrop crop: CGRect? = nil, rotation: Int = 0) {
        context.saveGState()
        context.textMatrix = .identity
        if let crop {
            let raw = SignatureStamp.originalRect(bounds, pageSize: crop.size, rotation: rotation)
            context.translateBy(x: crop.minX + raw.midX, y: crop.minY + raw.midY)
            context.rotate(by: CGFloat(rotation) * .pi / 180)
            let centered = CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
            CTFrameDraw(frame(in: centered), context)
        } else {
            CTFrameDraw(frame(in: bounds), context)
        }
        context.restoreGState()
    }
}

struct PDFPageTextEditor: View {
    let insert: (String, CGFloat, PDFPageTextColor) throws -> Void
    let cancel: () -> Void
    private let editing: Bool
    @State private var text: String
    @State private var size: CGFloat
    @State private var color: PDFPageTextColor
    @State private var error: String?
    @FocusState private var focused: Bool

    init(editing block: PDFPageText? = nil, insert: @escaping (String, CGFloat, PDFPageTextColor) throws -> Void,
         cancel: @escaping () -> Void) {
        self.insert = insert
        self.cancel = cancel
        editing = block != nil
        _text = State(initialValue: block?.text ?? "")
        _size = State(initialValue: block?.size ?? 14)
        _color = State(initialValue: block?.color ?? .black)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editing ? "编辑正文文字" : "添加正文文字").font(.headline)
                Spacer()
                if editing { SidePanelCloseButton(title: "关闭正文编辑", close: cancel) }
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(minHeight: 92, maxHeight: editing ? 220 : 92)
                .focused($focused)
                .accessibilityLabel("正文文字")
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.35)).allowsHitTesting(false) }
            HStack {
                Picker("字号", selection: $size) {
                    ForEach(AnnotationTextStyle.sizes, id: \.self) { size in Text("\(Int(size)) 磅").tag(size) }
                }
                Picker("颜色", selection: $color) {
                    ForEach(PDFPageTextColor.allCases, id: \.self) { color in Text(color.rawValue).tag(color) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(editing ? "应用修改" : "写入页面") {
                    do { try insert(text, size, color) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { focused = true }
    }
}

struct PDFPageTextSelection: Hashable {
    let pageIndex: Int
    let textIndex: Int
    let revision: UUID
}

extension Workspace {
    var selectedPageText: PDFPageText? {
        guard !previewsCreatedPDF, !readingLocked, !showsPageThumbnails, !placesPDFContentText, placingSignature == nil,
              let selected = pageTextSelection, selected.pageIndex == selection, selected.revision == revision,
              let page, let layer = signatureLayer(for: page), layer.texts.indices.contains(selected.textIndex) else { return nil }
        return layer.texts[selected.textIndex]
    }

    func pageTextIndex(at point: CGPoint, on page: PDFPage) -> Int? {
        guard !previewsCreatedPDF, !readingLocked, !busy, !showsPageThumbnails, !placesPDFContentText,
              placingSignature == nil, let layer = signatureLayer(for: page) else { return nil }
        return layer.texts.indices.reversed().first { layer.texts[$0].contains(point, on: page) }
    }

    func selectPageText(_ index: Int, on clickedPage: PDFPage) {
        guard let layer = signatureLayer(for: clickedPage), layer.texts.indices.contains(index) else { return }
        let pageIndex = document.index(for: clickedPage)
        if selection != pageIndex { selectPage(pageIndex) }
        pageTextSelection = PDFPageTextSelection(pageIndex: pageIndex, textIndex: index, revision: revision)
    }

    func updatePageContentText(_ selected: PDFPageTextSelection, input: String,
                               size: CGFloat, color: PDFPageTextColor) throws {
        guard !busy, placingSignature == nil, pageTextSelection == selected, let old = selectedPageText,
              let page, let layer = signatureLayer(for: page) else {
            throw FolioError(message: "当前页面已变化，请重新点击正文文字。")
        }
        let anchor = CGRect(origin: CGPoint(x: old.bounds.minX, y: old.bounds.maxY), size: .zero)
        let block = try PDFPageText.layout(input, size: size, color: color, at: old.pageRect(anchor, on: page).origin, on: page)
        var texts = layer.texts
        texts[selected.textIndex] = block
        let before = try snapshot()
        _ = try rebake(layer, items: layer.items, texts: texts)
        pushUndo(.snapshot(before))
        readingPoint = nil
        navigationToken = UUID()
        changed()
        pageTextSelection = PDFPageTextSelection(pageIndex: selected.pageIndex, textIndex: selected.textIndex, revision: revision)
        status = "已更新正文文字，可撤销"
    }

    func addPageContentText(_ input: String, size: CGFloat, color: PDFPageTextColor,
                            on original: PDFPage, at point: CGPoint) throws {
        let index = document.index(for: original)
        guard isMakingPDF, !previewsCreatedPDF, !readingLocked, !busy, placingSignature == nil,
              index != NSNotFound, page === original else {
            throw FolioError(message: "当前页面已变化，请重新点选文字位置。")
        }
        let block = try PDFPageText.layout(input, size: size, color: color, at: point, on: original)
        preparePageIdentities053()
        let before = try snapshot()
        if let layer = signatureLayer(for: original) {
            _ = try rebake(layer, items: layer.items, texts: layer.texts + [block])
        } else {
            let clean = try (original.copy() as? PDFPage).unwrap("无法复制当前页")
            for annotation in clean.annotations { clean.removeAnnotation(annotation) }
            let single = PDFDocument()
            single.insert(clean, at: 0)
            let bytes = try single.dataRepresentation().unwrap("无法读取当前页")
            let layer = SignatureLayer(base: bytes, preserved: true, size: original.bounds(for: .cropBox).size,
                                       rotation: original.rotation, items: [], page: original)
            _ = try rebake(layer, items: [], texts: [block])
        }
        // A forced OCR run must not restore the pre-edit source over the new page content.
        updateMeta(index) { $0.ocrOriginal = nil }
        pushUndo(.snapshot(before))
        placesPDFContentText = false
        readingPoint = nil
        navigationToken = UUID()
        changed()
        status = "已将文字写入页面正文，可撤销"
    }
}
