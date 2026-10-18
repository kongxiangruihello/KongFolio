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
        if TextImport.handles(url) { return try TextImport.document(from: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FolioError(message: "不支持或无法读取：\(url.lastPathComponent)") }
        let doc = PDFDocument()
        for i in 0..<CGImageSourceGetCount(source) {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let orientation = props?[kCGImagePropertyOrientation] as? Int32 ?? 1
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
            guard let oriented = context.createCGImage(ci, from: ci.extent), let page = PDFPage(image: NSImage(cgImage: oriented, size: .zero)) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0 else { throw FolioError(message: "图片内没有可读取的页面。") }
        return doc
    }
    // PDFKit thumbnail honors crop boxes and page rotation, returning upright pixels.
    static func render(_ page: PDFPage, maxDimension: CGFloat = 2200) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let size = CGSize(width: maxDimension, height: maxDimension)
        guard bounds.width > 0, bounds.height > 0,
              let image = page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw FolioError(message: "页面渲染失败。") }
        return image
    }
    static func adjusted(_ image: CGImage, _ values: ImageAdjustments) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        if let corners = values.perspective, corners.count == 4 {
            let extent = ci.extent
            let keys = ["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"]
            var params: [String: Any] = [:]
            for i in 0..<4 { params[keys[i]] = CIVector(x: extent.minX + corners[i].x * extent.width, y: extent.minY + corners[i].y * extent.height) }
            ci = ci.applyingFilter("CIPerspectiveCorrection", parameters: params)
        }
        if values.flip { ci = ci.oriented(.upMirrored) }
        for _ in 0..<((values.rotation % 4 + 4) % 4) { ci = ci.oriented(.right) }
        if values.straighten != 0 { ci = ci.applyingFilter("CIStraightenFilter", parameters: ["inputAngle": values.straighten * .pi / 180]) }
        if let crop = values.cropRect {
            let clipped = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clipped.isNull, clipped.width > 0.01, clipped.height > 0.01 else { throw FolioError(message: "裁剪区域太小。") }
            let e = ci.extent
            ci = ci.cropped(to: CGRect(x: e.minX + clipped.minX * e.width, y: e.minY + clipped.minY * e.height, width: clipped.width * e.width, height: clipped.height * e.height))
        }
        let inset = min(0.4, max(0, values.crop))
        ci = ci.cropped(to: ci.extent.insetBy(dx: ci.extent.width * inset, dy: ci.extent.height * inset))
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: values.brightness, kCIInputContrastKey: values.scan ? max(1.5, values.contrast) : values.contrast, kCIInputSaturationKey: values.scan ? 0 : values.saturation])
        ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: values.sharpness])
        if values.scan { ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.5, "inputHighlightAmount": 0.8]) }
        guard let result = context.createCGImage(ci, from: ci.extent) else { throw FolioError(message: "图片处理失败。") }
        return result
    }
    static func detectPaper(_ image: CGImage) throws -> [CGPoint] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1; request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.2; request.minimumSize = 0.25; request.quadratureTolerance = 40
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let rectangle = request.results?.first else { throw FolioError(message: "未找到清晰的纸张边缘，请使用框选裁剪或手动校正。") }
        return [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
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

    static func downscale(_ image: CGImage, maxDimension: CGFloat) throws -> CGImage {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FolioError(message: "无法创建预览图。") }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try ctx.makeImage().unwrap("无法创建预览图。")
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
    static func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.88) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw FolioError(message: "无法创建图片文件。") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FolioError(message: "图片写入失败。") }
    }
    static func subset(_ doc: PDFDocument, indexes: [Int]) -> PDFDocument {
        let output = PDFDocument()
        for index in indexes { if let page = doc.page(at: index)?.copy() as? PDFPage { output.insert(page, at: output.pageCount) } }
        return output
    }
}
