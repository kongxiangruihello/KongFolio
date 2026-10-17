import AppKit
import CoreText
import ImageIO
import PDFKit

enum CompressLevel: String, CaseIterable, Identifiable, Codable {
    case light = "轻度"
    case standard = "标准"
    case strong = "强力"
    var id: String { rawValue }

    /// Resolution the pictures on a page are redrawn at; 0 lets PDFKit decide (light).
    var dpi: Int {
        switch self {
        case .light: return 0
        case .standard: return 150
        case .strong: return 100
        }
    }

    var quality: Double {
        switch self {
        case .light: return 1
        case .standard: return 0.6
        case .strong: return 0.42
        }
    }

    var detail: String {
        switch self {
        case .light: return "让 PDFKit 重新编码页面中的图片，文字、矢量、链接、目录和批注都不变。效果因文件而异，不保证变小。"
        case .standard: return "含大图片的页面（扫描件、照片）以 150 DPI 重绘并保留可搜索文字；纯文字页原样保留。重绘页上的批注和链接会固化。"
        case .strong: return "与“标准”相同，但分辨率 100 DPI、画质更低，体积最小；小字号可能变模糊。"
        }
    }
}

struct CompressReport: Equatable {
    var before: Int
    var after: Int
    /// Pages redrawn from a lower-resolution picture, and pages left exactly as they were.
    var rebuilt: Int
    var kept: Int
    /// True when PDFKit re-encoded the pictures itself (the light level) instead of pages being redrawn here.
    var viaPDFKit = false

    var smaller: Bool { after < before }

    var summary: String {
        let sizes = "\(ByteCountFormatter.string(fromByteCount: Int64(before), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(after), countStyle: .file))"
        guard smaller else {
            if !viaPDFKit && rebuilt == 0 { return "没有找到可以压缩的大图片页面，未生成压缩文件" }
            return "此文件没有变小（\(sizes)），未生成压缩文件"
        }
        let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
        return "已压缩，减少 \(saved)%：\(sizes)" + (rebuilt + kept > 0 && rebuilt > 0 ? "（重绘 \(rebuilt) 页，原样保留 \(kept) 页）" : "")
    }
}

enum PDFCompressor {
    /// Pages with less picture data than this are not worth redrawing.
    static let minimumImageBytes = 30_000
    /// A redrawn page must be at least this much smaller than the pictures it replaces.
    static let requiredRatio = 0.75

    /// Bytes of the picture streams (page-level `XObject` images) that a page refers to.
    static func imageBytes(_ page: PDFPage) -> Int {
        guard let reference = page.pageRef, let dictionary = reference.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return 0 }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return 0 }
        final class Box { var total = 0 }
        let box = Box()
        CGPDFDictionaryApplyBlock(objects, { _, object, info in
            guard let info else { return true }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { return true }
            var length: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(streamDictionary, "Length", &length) {
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().total += Int(length)
            }
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.total
    }

    /// The page drawn from a JPEG at `dpi`, with its text kept as invisible text so it stays searchable and selectable.
    /// Annotations are flattened into the picture; links are not carried over.
    static func rebuild(_ page: PDFPage, dpi: Int, quality: Double) throws -> PDFPage {
        let crop = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let quarterTurn = abs(rotation % 180) == 90
        var box = CGRect(origin: .zero, size: quarterTurn ? CGSize(width: crop.height, height: crop.width) : crop.size)

        var options = ExportOptions()
        options.dpi = dpi
        options.quality = quality
        let rendered = try ExportServices.render(page, dpi: dpi)
        let jpeg = try ExportServices.encode(rendered, options: options, pdfJPEG: true)
        // An image made from JPEG data is embedded as it is (no recompression) when it is drawn into a PDF.
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw FolioError(message: "压缩图片读取失败")
        }

        let lines = textLines(of: page, crop: crop, rotation: rotation)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FolioError(message: "无法创建压缩页面")
        }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        for (text, rect) in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, max(4, rect.height * 0.85), nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.1)
            context.scaleBy(x: rect.width / max(1, width), y: 1)
            context.setTextDrawingMode(.invisible)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let result = PDFDocument(data: data as Data)?.page(at: 0) else { throw FolioError(message: "压缩页面生成失败") }
        return result
    }

    private static func textLines(of page: PDFPage, crop: CGRect, rotation: Int) -> [(String, CGRect)] {
        guard let selection = page.selection(for: crop) else { return [] }
        var result: [(String, CGRect)] = []
        for line in selection.selectionsByLine() {
            let text = ReadingServices.repairIdeographs(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bounds = line.bounds(for: page).offsetBy(dx: -crop.minX, dy: -crop.minY)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            result.append((text, SignatureStamp.uprightRect(bounds, pageSize: crop.size, rotation: rotation)))
        }
        return result
    }

    /// Compresses `document` in place (picture-heavy pages are replaced) and returns the new file.
    static func compress(_ document: PDFDocument, level: CompressLevel, original: Int, progress: (Double) -> Void) throws -> (data: Data, report: CompressReport) {
        if level == .light {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-compress-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try ExportServices.optimizedPDF(document, pages: Array(0..<document.pageCount), to: temporary)
            let data = try Data(contentsOf: temporary)
            progress(1)
            return (data, CompressReport(before: original, after: data.count, rebuilt: 0, kept: document.pageCount, viaPDFKit: true))
        }
        let outline = ReadingServices.outline(document)
        var rebuilt = 0
        let count = document.pageCount
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let pictures = imageBytes(page)
                if pictures >= minimumImageBytes {
                    let candidate = try rebuild(page, dpi: level.dpi, quality: level.quality)
                    let size = candidate.dataRepresentation?.count ?? Int.max
                    if Double(size) < Double(pictures) * requiredRatio {
                        document.removePage(at: index)
                        document.insert(candidate, at: index)
                        rebuilt += 1
                    }
                }
            }
            progress(Double(index + 1) / Double(count))
        }
        // Nothing to redraw: the file would only be written again, so say so instead of producing a copy.
        guard rebuilt > 0 else { return (Data(), CompressReport(before: original, after: original, rebuilt: 0, kept: count)) }
        ReadingServices.applyOutline(outline, to: document)
        let data = try document.dataRepresentation().unwrap("压缩保存失败")
        return (data, CompressReport(before: original, after: data.count, rebuilt: rebuilt, kept: count - rebuilt))
    }
}
