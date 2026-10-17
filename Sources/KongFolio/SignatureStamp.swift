import AppKit
import CoreGraphics
import PDFKit

/// What the PDF view must offer so a workspace can drive the signature placement overlay
/// (the view itself lives in PDFCanvas.swift, which the headless test runner does not compile).
@MainActor protocol SignaturePlacing: AnyObject {
    /// Shows the stamp; with `page` and `rect` it starts at that place on the page (moving a placed signature),
    /// otherwise in the middle of the view.
    func beginSignaturePlacement(_ image: CGImage, widthFraction: Double, page: PDFPage?, rect: CGRect?)
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

    /// The reverse of `uprightRect`: a rectangle in displayed-page coordinates back to the page's own coordinates.
    static func originalRect(_ rect: CGRect, pageSize: CGSize, rotation: Int) -> CGRect {
        let w = pageSize.width, h = pageSize.height
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGRect(x: w - rect.minY - rect.height, y: rect.minX, width: rect.height, height: rect.width)
        case 180: return CGRect(x: w - rect.maxX, y: h - rect.maxY, width: rect.width, height: rect.height)
        case 270: return CGRect(x: rect.minY, y: h - rect.minX - rect.width, width: rect.height, height: rect.width)
        default: return rect
        }
    }

    /// Whether a redraw of `page` can keep its annotations as annotations (an unrotated page that starts at the origin).
    static func preservesAnnotations(_ page: PDFPage) -> Bool {
        let crop = page.bounds(for: .cropBox)
        return page.rotation == 0 && abs(crop.minX) < 0.01 && abs(crop.minY) < 0.01
    }

    /// Redraws `source` (a page of a freshly serialized copy of the document) with the image on top and returns it as
    /// a new page. Page content stays vector. On an unrotated page the annotations stay editable annotations; on a
    /// rotated or offset page they are flattened into the page, the way page numbers are.
    static func bake(_ image: CGImage, onto source: PDFPage, userRect: CGRect) -> PDFPage? {
        bake([(image, userRect)], onto: source, preserve: preservesAnnotations(source))
    }

    /// The general form: several pictures, and annotations to add on top of `source`'s own (`extras`).
    /// `source` annotations are flattened into the page unless `preserve` is set.
    static func bake(_ images: [(image: CGImage, rect: CGRect)], onto source: PDFPage, preserve: Bool, extras: [PDFAnnotation] = []) -> PDFPage? {
        guard let reference = source.pageRef else { return nil }
        let crop = source.bounds(for: .cropBox)
        let rotation = source.rotation
        let quarterTurn = abs(rotation % 180) == 90
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
        for (image, rect) in images {
            context.draw(image, in: uprightRect(rect, pageSize: crop.size, rotation: rotation))
        }
        context.endPDFPage()
        context.closePDF()
        guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        for annotation in (preserve ? source.annotations : []) + extras {
            if let copy = annotation.copy() as? PDFAnnotation { page.addAnnotation(copy) }
        }
        return page
    }
}

/// A signature placed on a page, kept so it can be moved, resized or removed later in the same session.
struct PlacedSignature: Identifiable {
    let id: UUID
    var png: Data
    /// In the coordinates of the page as it was before the signatures were drawn.
    var rect: CGRect
}

/// The state needed to redraw one page with a different set of signatures: the page before any signature was drawn.
/// It is tied to the page object that is currently in the document, so anything that replaces the page (an undo,
/// reordering, rotating, OCR) simply ends the ability to move its signatures; the signatures themselves stay.
final class SignatureLayer {
    let base: Data
    let preserved: Bool
    let size: CGSize
    let rotation: Int
    var items: [PlacedSignature]
    var page: PDFPage

    init(base: Data, preserved: Bool, size: CGSize, rotation: Int, items: [PlacedSignature], page: PDFPage) {
        self.base = base; self.preserved = preserved; self.size = size; self.rotation = rotation; self.items = items; self.page = page
    }

    /// Where the signature appears on the page that is in the document.
    func shownRect(_ item: PlacedSignature) -> CGRect {
        preserved ? item.rect : SignatureStamp.uprightRect(item.rect, pageSize: size, rotation: rotation)
    }

    /// A rectangle on the page that is in the document, in the coordinates the signatures are stored in.
    func storedRect(fromShown rect: CGRect) -> CGRect {
        preserved ? rect : SignatureStamp.originalRect(rect, pageSize: size, rotation: rotation)
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
        guard let data = template.image, let image = Self.decodePNG(data) else { insertSignature(template); return }
        guard let view = pdfView as? SignaturePlacing else { return }
        tool = .select
        placingSignature = template
        view.beginSignaturePlacement(image, widthFraction: signatureWidth, page: nil, rect: nil)
        status = "拖动签名到位置，拖角调整大小；回车确认，Esc 取消"
    }

    private static func decodePNG(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    func setSignatureWidth(_ fraction: Double) {
        signatureWidth = fraction
        (pdfView as? SignaturePlacing)?.resizeSignaturePlacement(widthFraction: fraction)
    }

    func cancelSignaturePlacement() {
        if let moving = movingSignature {
            // The signature was lifted off the page; put it back where it was.
            movingSignature = nil
            moveSnapshot = nil
            var items = moving.layer.items
            items.append(moving.item)
            report { try rebake(moving.layer, items: items) }
            changed()
        }
        (pdfView as? SignaturePlacing)?.endSignaturePlacement()
        placingSignature = nil
    }

    /// Writes the signature (new, or one that was picked up) into the PDF at the place shown on the page.
    func confirmSignaturePlacement() {
        guard let template = placingSignature, let data = template.image, let image = Self.decodePNG(data),
              let placement = (pdfView as? SignaturePlacing)?.signaturePlacement() else { cancelSignaturePlacement(); return }
        let index = document.index(for: placement.page)
        guard index != NSNotFound else { cancelSignaturePlacement(); return }
        do {
            if let layer = signatureLayer(for: placement.page) {
                // The page already has movable signatures (or one was just picked up from it).
                let item = PlacedSignature(id: movingSignature?.item.id ?? UUID(), png: data, rect: layer.storedRect(fromShown: placement.rect))
                if let snapshot = moveSnapshot { pushUndo(.snapshot(snapshot)) } else { checkpoint() }
                try rebake(layer, items: layer.items + [item])
            } else {
                // The page object may be stale after in-memory edits, so the page is redrawn from a freshly serialized
                // copy of that one page; the rest of the document is not touched.
                let single = DocumentServices.subset(document, indexes: [index])
                let committed = try PDFDocument(data: single.dataRepresentation().unwrap("无法读取当前页")).unwrap("无法读取当前页")
                let page = try committed.page(at: 0).unwrap("页面读取失败")
                let preserve = SignatureStamp.preservesAnnotations(page)
                let baked = try SignatureStamp.bake([(image, placement.rect)], onto: page, preserve: preserve).unwrap("无法把签名写入页面")
                // The page without signatures, and without annotations that stay annotations, is what later redraws start from.
                let baseDocument = try PDFDocument(data: single.dataRepresentation().unwrap("无法读取当前页")).unwrap("无法读取当前页")
                if preserve, let basePage = baseDocument.page(at: 0) { for annotation in basePage.annotations { basePage.removeAnnotation(annotation) } }
                let baseData = try baseDocument.dataRepresentation().unwrap("无法保存页面")
                let crop = page.bounds(for: .cropBox)
                checkpoint()
                document.removePage(at: index)
                document.insert(baked, at: index)
                ReadingServices.applyOutline(outlineEntries, to: document)
                let layer = SignatureLayer(base: baseData, preserved: preserve, size: crop.size, rotation: page.rotation,
                                           items: [PlacedSignature(id: UUID(), png: data, rect: placement.rect)], page: baked)
                signatureLayers[ObjectIdentifier(baked)] = layer
            }
            movingSignature = nil
            moveSnapshot = nil
            (pdfView as? SignaturePlacing)?.endSignaturePlacement()
            placingSignature = nil
            selection = index
            changed()
            status = "签名已放置（可撤销）；双击签名或右键可再次移动"
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Moving a placed signature

    /// The movable signatures of a page that is in the document, if it still is the page they were drawn on.
    func signatureLayer(for page: PDFPage) -> SignatureLayer? {
        guard let layer = signatureLayers[ObjectIdentifier(page)], layer.page === page, page.rotation == 0, document.index(for: page) != NSNotFound else { return nil }
        return layer
    }

    /// The placed signature under `point` (in the page's coordinates), topmost first.
    func placedSignature(on page: PDFPage, at point: CGPoint) -> (layer: SignatureLayer, item: PlacedSignature)? {
        guard let layer = signatureLayer(for: page) else { return nil }
        for item in layer.items.reversed() where layer.shownRect(item).insetBy(dx: -2, dy: -2).contains(point) { return (layer, item) }
        return nil
    }

    /// Lifts a placed signature off the page and shows it as a stamp that can be moved and resized.
    func beginMovingSignature(_ item: PlacedSignature, in layer: SignatureLayer) {
        guard placingSignature == nil, let view = pdfView as? SignaturePlacing, let image = Self.decodePNG(item.png) else { return }
        do {
            moveSnapshot = try snapshot()
            movingSignature = (layer, item)
            let page = try rebake(layer, items: layer.items.filter { $0.id != item.id })
            let shown = layer.shownRect(item)
            let width = page.bounds(for: .cropBox).width
            tool = .select
            placingSignature = SignatureTemplate(name: "移动签名", pdf: Data(), image: item.png)
            signatureWidth = min(0.8, max(0.08, Double(shown.width / max(1, width))))
            view.beginSignaturePlacement(image, widthFraction: signatureWidth, page: page, rect: shown)
            changed()
            status = "拖动移动，拖角缩放；回车确认，Esc 放回原处"
        } catch {
            movingSignature = nil; moveSnapshot = nil
            self.error = error.localizedDescription
        }
    }

    /// Takes a placed signature off the page for good (undoable).
    func removePlacedSignature(_ item: PlacedSignature, in layer: SignatureLayer) {
        do {
            checkpoint()
            try rebake(layer, items: layer.items.filter { $0.id != item.id })
            changed()
            status = "已删除签名（可撤销）"
        } catch { self.error = error.localizedDescription }
    }

    /// Redraws the page with exactly `items`, keeping the annotations that were added to it since.
    @discardableResult
    private func rebake(_ layer: SignatureLayer, items: [PlacedSignature]) throws -> PDFPage {
        let old = layer.page
        let index = document.index(for: old)
        guard index != NSNotFound, let basePage = PDFDocument(data: layer.base)?.page(at: 0) else { throw FolioError(message: "页面已变化，无法再移动这个签名。") }
        let images = items.compactMap { item in Self.decodePNG(item.png).map { (image: $0, rect: item.rect) } }
        let page = try SignatureStamp.bake(images, onto: basePage, preserve: layer.preserved, extras: old.annotations).unwrap("无法重绘页面")
        document.removePage(at: index)
        document.insert(page, at: index)
        ReadingServices.applyOutline(outlineEntries, to: document)
        signatureLayers[ObjectIdentifier(old)] = nil
        layer.page = page
        layer.items = items
        signatureLayers[ObjectIdentifier(page)] = layer
        return page
    }
}
