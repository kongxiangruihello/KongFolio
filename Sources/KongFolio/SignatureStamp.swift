import AppKit
import CoreGraphics
import PDFKit

/// What the PDF view must offer so a workspace can drive the signature placement overlay
/// (the view itself lives in PDFCanvas.swift, which the headless test runner does not compile).
@MainActor protocol SignaturePlacing: AnyObject {
    func beginSignaturePlacement(_ image: CGImage, widthFraction: Double)
    func resizeSignaturePlacement(widthFraction: Double)
    /// The page under the stamp and the stamp's rectangle in that page's coordinate space; nil when no stamp is shown.
    func signaturePlacement() -> (page: PDFPage, rect: CGRect)?
    func endSignaturePlacement()
}

/// Puts a signature image onto a page.
enum SignatureStamp {
    /// A rectangle given in the page's own (unrotated) coordinates, expressed in the coordinates of the page as it is
    /// shown once /Rotate has been applied. PDFKit reports rectangles in the former, a redrawn page is in the latter.
    static func uprightRect(_ rect: CGRect, pageSize: CGSize, rotation: Int) -> CGRect {
        let w = pageSize.width, h = pageSize.height
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGRect(x: rect.minY, y: w - rect.maxX, width: rect.height, height: rect.width)
        case 180: return CGRect(x: w - rect.maxX, y: h - rect.maxY, width: rect.width, height: rect.height)
        case 270: return CGRect(x: h - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default: return rect
        }
    }

    /// The signature's rectangle: `width` points wide, the image's aspect, centred on `center`, kept inside `bounds`.
    static func fit(aspect: CGFloat, width: CGFloat, center: CGPoint, in bounds: CGRect) -> CGRect {
        let w = min(width, bounds.width), h = min(w / max(aspect, 0.01), bounds.height)
        let size = CGSize(width: h * aspect > w ? w : h * aspect, height: h)
        let x = min(max(center.x - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(center.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Redraws `source` (a page of a freshly serialized copy of the document) with the image on top and returns it as
    /// a new page. Page content stays vector. On an unrotated page the annotations stay editable annotations; on a
    /// rotated or offset page they are flattened into the page, the way page numbers are.
    static func bake(_ image: CGImage, onto source: PDFPage, userRect: CGRect) -> PDFPage? {
        guard let reference = source.pageRef else { return nil }
        let crop = source.bounds(for: .cropBox)
        let rotation = source.rotation
        let quarterTurn = abs(rotation % 180) == 90
        let preserve = rotation == 0 && abs(crop.minX) < 0.01 && abs(crop.minY) < 0.01
        var box = CGRect(origin: .zero, size: quarterTurn ? CGSize(width: crop.height, height: crop.width) : crop.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.saveGState()
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        if !preserve {
            for annotation in source.annotations where !["Link", "Widget", "Popup"].contains(annotation.type ?? "") {
                annotation.draw(with: .cropBox, in: context)
            }
        }
        context.restoreGState()
        context.interpolationQuality = .high
        context.draw(image, in: uprightRect(userRect, pageSize: crop.size, rotation: rotation))
        context.endPDFPage()
        context.closePDF()
        guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        if preserve {
            for annotation in source.annotations {
                if let copy = annotation.copy() as? PDFAnnotation { page.addAnnotation(copy) }
            }
        }
        return page
    }
}

extension Workspace {
    private var signaturesFile: URL { storage.appendingPathComponent("Signatures.json") }

    private func storeSignatures(_ updated: [SignatureTemplate]) {
        report {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: signaturesFile, options: .atomic)
            signatures = updated
        }
    }

    /// Saves an imported, processed signature in the library.
    func addSignatureImage(_ image: CGImage, name: String? = nil) {
        guard let png = SignatureImage.pngData(image) else { error = "无法保存这张签名图片。"; return }
        let template = SignatureTemplate(name: name ?? "图片签名 \(signatures.filter { $0.image != nil }.count + 1)", pdf: Data(), image: png)
        storeSignatures(signatures + [template])
        status = "签名已保存在本机"
    }

    func renameSignature(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        storeSignatures(signatures.map { var t = $0; if t.id == id { t.name = trimmed }; return t })
    }

    /// Shows the signature on the page; it is only written into the PDF by `confirmSignaturePlacement`.
    func beginPlacing(_ template: SignatureTemplate) {
        guard let data = template.image, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { insertSignature(template); return }
        guard let view = pdfView as? SignaturePlacing else { return }
        tool = .select
        placingSignature = template
        view.beginSignaturePlacement(image, widthFraction: signatureWidth)
        status = "拖动签名到位置，拖角调整大小；回车确认，Esc 取消"
    }

    func setSignatureWidth(_ fraction: Double) {
        signatureWidth = fraction
        (pdfView as? SignaturePlacing)?.resizeSignaturePlacement(widthFraction: fraction)
    }

    func cancelSignaturePlacement() {
        (pdfView as? SignaturePlacing)?.endSignaturePlacement()
        placingSignature = nil
    }

    func confirmSignaturePlacement() {
        guard let template = placingSignature, let data = template.image,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let placement = (pdfView as? SignaturePlacing)?.signaturePlacement() else { cancelSignaturePlacement(); return }
        let index = document.index(for: placement.page)
        guard index != NSNotFound else { cancelSignaturePlacement(); return }
        do {
            // The page object may be stale after in-memory edits, so the page is redrawn from a committed copy.
            let committed = try PDFDocument(data: pdfData()).unwrap("无法读取当前文档")
            let page = try committed.page(at: index).unwrap("页面读取失败")
            let baked = try SignatureStamp.bake(image, onto: page, userRect: placement.rect).unwrap("无法把签名写入页面")
            checkpoint()
            document.removePage(at: index)
            document.insert(baked, at: index)
            ReadingServices.applyOutline(outlineEntries, to: document)
            cancelSignaturePlacement()
            selection = index
            changed()
            status = "签名已放置（可撤销）"
        } catch { self.error = error.localizedDescription }
    }
}
