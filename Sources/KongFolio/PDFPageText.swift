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
        let local = CGPoint(x: point.x - crop.minX, y: point.y - crop.minY)
        let anchor = SignatureStamp.uprightRect(CGRect(origin: local, size: .zero), pageSize: crop.size, rotation: rotation).origin
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
    @State private var text = ""
    @State private var size: CGFloat = 14
    @State private var color = PDFPageTextColor.black
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加正文文字").font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(height: 92)
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
                Button("写入页面") {
                    do { try insert(text, size, color) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { focused = true }
    }
}

extension Workspace {
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
            let holder = try PDFDocument(data: bytes).unwrap("无法解析当前页")
            let source = try holder.page(at: 0).unwrap("无法读取页面内容")
            let reference = try source.pageRef.unwrap("无法读取页面内容")
            let crop = source.bounds(for: .cropBox)
            let replacement = try SignatureStamp.redrawInPageCoordinates(source, reference: reference) { context in
                block.draw(in: context, originalCrop: crop, rotation: source.rotation)
            }.unwrap("无法写入正文文字")
            withExtendedLifetime(holder) {}
            replacePage(original, with: replacement, at: index, preservingAnnotations: true)
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
