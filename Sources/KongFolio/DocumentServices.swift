import AppKit
import PDFKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import UniformTypeIdentifiers

struct FolioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct RecognizedLine: Codable, Equatable {
    var text: String
    var box: CGRect
    var confidence: Float = 1
    /// True when the box is a placeholder (vertical-text mode has no per-line geometry).
    var approximate: Bool? = nil
}
struct ImageAdjustments: Equatable, Codable {
    var cropRect: CGRect?
    var straighten = 0.0
    var perspective: [CGPoint]?
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var sharpness = 0.0
    var crop = 0.0
    var rotation = 0
    var flip = false
    var scan = false
}
enum DocumentServices {
    static let context = CIContext()
    /// A file marked "no modification" (owner-restricted) is rebuilt from copies of its pages, which carry no
    /// encryption, so annotations and edits are saved like in any other file. Other files are returned as they are.
    static func unrestricted(_ document: PDFDocument) -> PDFDocument {
        guard document.isEncrypted, !document.allowsDocumentChanges else { return document }
        let copy = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { return document }
            copy.insert(page, at: copy.pageCount)
        }
        ReadingServices.applyOutline(ReadingServices.outline(document), to: copy)
        return copy
    }

    static func load(_ url: URL) throws -> PDFDocument {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                throw FolioError(message: "无法打开 PDF，文件可能损坏或需要密码。")
            }
            return unrestricted(document)
        }
        if ImageImport.handles(url) { return try ImageImport.document(url) }
        if TextImport.handles(url) { return try TextImport.document(from: url) }
        throw FolioError(message: "不支持的文件：\(url.lastPathComponent)。支持 PDF、图片、Markdown、HTML 与纯文本。")
    }
    // PDFKit thumbnail honors crop boxes and page rotation, returning upright pixels.
    static func render(_ page: PDFPage, maxDimension: CGFloat = 2200) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let size = CGSize(width: maxDimension, height: maxDimension)
        guard bounds.width > 0, bounds.height > 0,
              let image = page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw FolioError(message: "页面渲染失败。") }
        return image
    }
    static var supportedOCRLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    /// Pixel size for OCR rendering: the page's longest side at `dpi`, kept within Vision-friendly limits.
    static func ocrPixelDimension(for page: PDFPage, dpi: Int) -> CGFloat {
        let bounds = page.bounds(for: .cropBox)
        return min(7000, max(1600, max(bounds.width, bounds.height) * CGFloat(dpi) / 72))
    }

    static func recognize(_ image: CGImage, languages: [String] = OCRSettings().languages) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = Set(supportedOCRLanguages)
        let chosen = languages.filter { supported.isEmpty || supported.contains($0) }
        request.recognitionLanguages = chosen.isEmpty ? OCRSettings().languages : chosen
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, box: observation.boundingBox, confidence: $0.confidence) }
        }
    }

    /// Vertical-text (竖排) recognition: columns are re-laid out as horizontal rows first. See VerticalText.swift.
    static func recognizeVertical(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        try VerticalText.recognize(image, languages: languages)
    }

    // Adds actual invisible PDF text, not a visible annotation pretending to be OCR.
    // Original page content is retained; annotations are flattened into the OCR result.
    static func searchablePage(_ page: PDFPage, lines: [RecognizedLine]) throws -> PDFPage {
        let original = page.bounds(for: .cropBox)
        let isQuarterTurn = abs(page.rotation % 180) == 90
        var rect = CGRect(origin: .zero, size: isQuarterTurn ? CGSize(width: original.height, height: original.width) : original.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else { throw FolioError(message: "无法创建 OCR 页面。") }
        ctx.beginPDFPage(nil)
        // Upright rendering makes Vision geometry and rotated/cropped PDF geometry identical.
        // `pageRef` does not see rotation or crop changes made in memory until the page is saved,
        // so draw from a freshly serialized copy (verified on macOS 15 and 26 in CI).
        let committed = DocumentServices.subset(page.document ?? PDFDocument(), indexes: page.document.map { [$0.index(for: page)] } ?? [])
        if committed.pageCount == 0, let copy = page.copy() as? PDFPage { committed.insert(copy, at: 0) }
        let holder = committed.dataRepresentation().flatMap { PDFDocument(data: $0) }
        guard let pageRef = holder?.page(at: 0)?.pageRef ?? page.pageRef else { throw FolioError(message: "无法读取 PDF 页面内容。") }
        ctx.saveGState()
        ctx.concatenate(pageRef.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(pageRef)
        // Flatten existing annotations at their original PDF coordinates.
        for annotation in page.annotations { annotation.draw(with: .cropBox, in: ctx) }
        ctx.restoreGState()
        for line in lines {
            let box = CGRect(x: line.box.minX * rect.width, y: line.box.minY * rect.height, width: line.box.width * rect.width, height: line.box.height * rect.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(4, box.height * 0.85), nil)
            let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let text = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(text, nil, nil, nil))
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.1)
            ctx.scaleBy(x: box.width / max(1, width), y: 1)
            ctx.setTextDrawingMode(.invisible)
            ctx.textPosition = .zero
            CTLineDraw(text, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage(); ctx.closePDF()
        withExtendedLifetime(holder) {}
        guard let result = PDFDocument(data: data as Data)?.page(at: 0) else { throw FolioError(message: "OCR PDF 生成失败。") }
        return result
    }
    static func subset(_ doc: PDFDocument, indexes: [Int]) -> PDFDocument {
        let output = PDFDocument()
        for index in indexes { if let page = doc.page(at: index)?.copy() as? PDFPage { output.insert(page, at: output.pageCount) } }
        return output
    }
}
