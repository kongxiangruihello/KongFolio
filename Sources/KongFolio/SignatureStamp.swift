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
    func resizePageImage(widthInPoints: CGFloat)
    /// The page under the stamp and the stamp's rectangle in that page's coordinate space; nil when no stamp is shown.
    func signaturePlacement() -> (page: PDFPage, rect: CGRect)?
    func endSignaturePlacement()
}
extension SignaturePlacing {
    func resizePageImage(widthInPoints: CGFloat) {}
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
        if preserve && !preservesAnnotations(source) {
            return bakeInPageCoordinates(images,onto:source,reference:reference,extras:extras)
        }
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
            let local = rect.offsetBy(dx:-crop.minX,dy:-crop.minY)
            context.draw(image, in: uprightRect(local, pageSize: crop.size, rotation: rotation))
        }
        context.endPDFPage()
        context.closePDF()
        guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        for annotation in (preserve ? source.annotations : []) + extras {
            if let copy = annotation.copy() as? PDFAnnotation { page.addAnnotation(copy) }
        }
        return page
    }

    /// Preserve the PDF's coordinate space so links, widgets and ink keep their original positions.
    private static func bakeInPageCoordinates(_ images: [(image:CGImage,rect:CGRect)], onto source: PDFPage,
                                              reference: CGPDFPage, extras: [PDFAnnotation]) -> PDFPage? {
        let data = NSMutableData()
        var media = source.bounds(for:.mediaBox)
        guard let consumer = CGDataConsumer(data:data),
              let context = CGContext(consumer:consumer,mediaBox:&media,nil) else { return nil }
        let boxes: [(CFString,PDFDisplayBox)] = [
            (kCGPDFContextMediaBox,.mediaBox),(kCGPDFContextCropBox,.cropBox),
            (kCGPDFContextBleedBox,.bleedBox),(kCGPDFContextTrimBox,.trimBox),(kCGPDFContextArtBox,.artBox)
        ]
        var info: [String:Data] = [:]
        for (key,box) in boxes {
            var bounds = source.bounds(for:box)
            info[key as String] = Data(bytes:&bounds,count:MemoryLayout<CGRect>.size)
        }
        context.beginPDFPage(info as CFDictionary)
        context.drawPDFPage(reference)
        context.interpolationQuality = .high
        let rotation = source.rotation
        let quarterTurn = abs(rotation % 180) == 90
        for (image,rect) in images {
            let size = quarterTurn ? CGSize(width:rect.height,height:rect.width) : rect.size
            context.saveGState()
            context.translateBy(x:rect.midX,y:rect.midY)
            context.rotate(by:CGFloat(rotation) * .pi / 180)
            context.draw(image,in:CGRect(x:-size.width/2,y:-size.height/2,width:size.width,height:size.height))
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let page = PDFDocument(data:data as Data)?.page(at:0) else { return nil }
        page.rotation = rotation
        for annotation in source.annotations + extras {
            if let copy = annotation.copy() as? PDFAnnotation { page.addAnnotation(copy) }
        }
        return page
    }

}

/// A placed signature, persisted with its editing source in projects and local PDF metadata.
struct PlacedSignature: Identifiable, Codable {
    let id: UUID
    var png: Data
    /// In the coordinates of the page as it was before the signatures were drawn.
    var rect: CGRect
    var isPageImage: Bool? = nil
    var label: String { isPageImage == true ? "图片" : "签名" }
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
    let shownBounds: CGRect
    private lazy var baseOrigin = PDFDocument(data:base)?.page(at:0)?.bounds(for:.cropBox).origin ?? .zero

    init(base: Data, preserved: Bool, size: CGSize, rotation: Int, items: [PlacedSignature], page: PDFPage) {
        self.base = base; self.preserved = preserved; self.size = size; self.rotation = rotation; self.items = items; self.page = page; self.shownBounds = page.bounds(for: .cropBox)
    }

    /// Where the signature appears on the page that is in the document.
    func shownRect(_ item: PlacedSignature) -> CGRect {
        guard !preserved else { return item.rect }
        let local = item.rect.offsetBy(dx:-baseOrigin.x,dy:-baseOrigin.y)
        return SignatureStamp.uprightRect(local,pageSize:size,rotation:rotation)
    }

    /// A rectangle on the page that is in the document, in the coordinates the signatures are stored in.
    func storedRect(fromShown rect: CGRect) -> CGRect {
        guard !preserved else { return rect }
        let local = SignatureStamp.originalRect(rect,pageSize:size,rotation:rotation)
        return local.offsetBy(dx:baseOrigin.x,dy:baseOrigin.y)
    }
}

extension Workspace {
    private var signaturesFile: URL { storage.appendingPathComponent("Signatures.json") }

    @discardableResult func updateSignatureLibrary(_ mutate:(inout [SignatureTemplate])->Void) -> Bool {
        do {
            let updated = try SignatureLibrary.update(storage:storage,mutate)
            signatures = updated
            for tab in store?.tabs ?? [] where tab.workspace?.storage.standardizedFileURL == storage.standardizedFileURL { tab.workspace?.signatures = updated }
            return true
        } catch { self.error = "签名尚未保存："+error.localizedDescription; return false }
    }
    func refreshSignatureLibrary() {
        do { signatures = try SignatureLibrary.read(storage:storage) }
        catch { self.error = "签名库未能读取，原文件已保留："+error.localizedDescription }
    }
    /// Commit to disk before dismissing the import sheet. Every mutation merges the current shared library.
    @discardableResult func addSignatureImage(_ image:CGImage,name:String? = nil) -> SignatureTemplate? {
        guard let png = SignatureImage.pngData(image) else { error = "无法保存这张签名图片。"; return nil }
        let template = SignatureTemplate(name:name ?? "图片签名",pdf:Data(),image:png)
        guard updateSignatureLibrary({ $0.append(template) }) else { return nil }
        status = "签名已保存在本机"; return template
    }
    func renameSignature(_ id:UUID,to name:String) {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines); guard !trimmed.isEmpty else { return }
        _ = updateSignatureLibrary { list in if let i = list.firstIndex(where:{$0.id == id}) { list[i].name = trimmed } }
    }
    /// Shows the signature on the page; it is only written into the PDF by `confirmSignaturePlacement`.
    func beginPlacing(_ template: SignatureTemplate) {
        guard !readingLocked else { status = "请先切换到编辑模式";return }
        guard placingSignature?.isPageImage != true else { status = "请先完成图片放置";return }
        guard let data = template.image, let image = Self.decodePNG(data) else { insertSignature(template); return }
        guard let view = pdfView as? SignaturePlacing else { return }
        showImagePlacement(template,image:image,in:view)
    }

    func beginPlacingPageImage(_ image: CGImage, png: Data, on page: PDFPage) {
        guard !readingLocked, !busy, placingSignature == nil, self.page === page,
              let view = pdfView as? SignaturePlacing else { return }
        let template = SignatureTemplate(name:"页面图片",pdf:Data(),image:png,isPageImage:true)
        pageImageTarget = page
        showImagePlacement(template,image:image,in:view)
    }

    private func showImagePlacement(_ template: SignatureTemplate, image: CGImage, in view: SignaturePlacing) {
        tool = .select
        placingSignature = template
        if template.isPageImage == true, let page, let pdfView {
            let pageFrame = pdfView.convert(page.bounds(for:.cropBox),from:page)
            let visible = pageFrame.intersection(pdfView.bounds)
            if !visible.isEmpty {
                let rect = SignatureStamp.fit(aspect:CGFloat(image.width)/CGFloat(image.height),
                                              width:visible.width*0.45,center:CGPoint(x:visible.midX,y:visible.midY),in:visible)
                view.beginSignaturePlacement(image,widthFraction:0.45,page:page,rect:pdfView.convert(rect,to:page))
            } else {
                view.beginSignaturePlacement(image,widthFraction:0.45,page:nil,rect:nil)
            }
            updatePageImageSize()
            status = "拖动图片调整位置，拖角调整大小；回车确认，Esc 取消"
        } else {
            view.beginSignaturePlacement(image,widthFraction:signatureWidth,page:nil,rect:nil)
            status = "拖动签名到位置，拖角调整大小；回车确认，Esc 取消"
        }
    }

    private static func decodePNG(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    func updatePageImageSize() {
        guard placingSignature?.isPageImage == true,
              let placement = (pdfView as? SignaturePlacing)?.signaturePlacement() else { return }
        let quarterTurn = abs(placement.page.rotation % 180) == 90
        pageImageWidthPoints = quarterTurn ? placement.rect.height : placement.rect.width
    }

    func setPageImageWidth(_ points: Double) {
        guard placingSignature?.isPageImage == true, points.isFinite, points > 0 else { return }
        (pdfView as? SignaturePlacing)?.resizePageImage(widthInPoints:points)
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
        pageImageTarget = nil
        pageImageWidthPoints = nil
    }

    /// Writes the signature (new, or one that was picked up) into the PDF at the place shown on the page.
    func confirmSignaturePlacement() {
        guard let template = placingSignature, let data = template.image, let image = Self.decodePNG(data),
              let placement = (pdfView as? SignaturePlacing)?.signaturePlacement() else { cancelSignaturePlacement(); return }
        let index = document.index(for: placement.page)
        guard index != NSNotFound else { cancelSignaturePlacement(); return }
        if let target = pageImageTarget, target !== placement.page {
            if document.index(for:target) == NSNotFound {
                cancelSignaturePlacement()
                status = "原页面已变化，请重新导入图片。"
            } else { status = "请把图片拖回要插入的页面后确认。" }
            return
        }
        let label = template.isPageImage == true ? "图片" : "签名"
        let rect: CGRect
        if template.isPageImage == true {
            let proposed = placement.rect
            rect = SignatureStamp.fit(aspect:proposed.width/max(proposed.height,0.01),
                                      width:proposed.width,center:CGPoint(x:proposed.midX,y:proposed.midY),
                                      in:placement.page.bounds(for:.cropBox))
        } else { rect = placement.rect }
        do {
            if let layer = signatureLayer(for: placement.page) {
                // The page already has movable signatures (or one was just picked up from it).
                let item = PlacedSignature(id: movingSignature?.item.id ?? UUID(), png: data, rect: layer.storedRect(fromShown: rect), isPageImage: template.isPageImage)
                if let snapshot = moveSnapshot { pushUndo(.snapshot(snapshot)) } else { checkpoint() }
                try rebake(layer, items: layer.items + [item])
            } else {
                try addFirstPlacedImage(image,png:data,rect:rect,template:template,page:placement.page,index:index)
            }
            movingSignature = nil
            moveSnapshot = nil
            (pdfView as? SignaturePlacing)?.endSignaturePlacement()
            placingSignature = nil
            pageImageTarget = nil
            pageImageWidthPoints = nil
            selection = index
            changed()
            status = label+"已放置，可撤销。双击或右键可再次移动。"
        } catch { self.error = error.localizedDescription }
    }

    private func addFirstPlacedImage(_ image:CGImage,png:Data,rect:CGRect,template:SignatureTemplate,page original:PDFPage,index:Int) throws {
        let isPageImage = template.isPageImage == true
        let preserve = isPageImage || SignatureStamp.preservesAnnotations(original)
        let clean = try (original.copy() as? PDFPage).unwrap("无法复制当前页")
        if preserve { for annotation in clean.annotations { clean.removeAnnotation(annotation) } }
        let single = PDFDocument()
        single.insert(clean,at:0)
        let base = try single.dataRepresentation().unwrap("无法保存页面")
        let committed = try PDFDocument(data:base).unwrap("无法读取当前页")
        let page = try committed.page(at:0).unwrap("页面读取失败")
        let label = isPageImage ? "图片" : "签名"
        let baked = try SignatureStamp.bake([(image,rect)],onto:page,preserve:preserve).unwrap("无法把"+label+"写入页面")
        let crop = page.bounds(for:.cropBox)
        checkpoint()
        replacePage(original,with:baked,at:index,preservingAnnotations:preserve)
        let item = PlacedSignature(id:UUID(),png:png,rect:rect,isPageImage:template.isPageImage)
        signatureLayers[ObjectIdentifier(baked)] = SignatureLayer(base:base,preserved:preserve,size:crop.size,
                                                                 rotation:page.rotation,items:[item],page:baked)
    }

    private func replacePage(_ old:PDFPage,with page:PDFPage,at index:Int,preservingAnnotations:Bool) {
        let annotations = preservingAnnotations ? old.annotations : []
        var links: [(annotation:PDFAnnotation, action:Bool, page:Int, point:CGPoint, zoom:CGFloat)] = []
        for number in 0..<(preservingAnnotations ? document.pageCount : 0) {
            guard let source = document.page(at:number) else { continue }
            for annotation in source.annotations where annotation.type == "Link" || annotation.type == "Widget" {
                let action = annotation.action as? PDFActionGoTo
                guard let destination = annotation.destination ?? action?.destination, let target = destination.page,
                      source === old || target === old else { continue }
                let targetIndex = document.index(for:target)
                guard targetIndex != NSNotFound else { continue }
                links.append((annotation,annotation.destination == nil,targetIndex,destination.point,destination.zoom))
            }
        }
        for annotation in annotations { old.removeAnnotation(annotation) }
        document.removePage(at:index)
        document.insert(page,at:index)
        for annotation in annotations { page.addAnnotation(annotation) }
        for link in links {
            guard let target = document.page(at:link.page) else { continue }
            let destination = PDFDestination(page:target,at:link.point)
            destination.zoom = link.zoom
            if link.action { link.annotation.action = PDFActionGoTo(destination:destination) }
            else { link.annotation.destination = destination }
        }
        ReadingServices.applyOutline(outlineEntries,to:document)
    }

    // MARK: Moving a placed signature

    /// The movable signatures of a page that is in the document, if it still is the page they were drawn on.
    func signatureLayer(for page: PDFPage) -> SignatureLayer? {
        guard let layer = signatureLayers[ObjectIdentifier(page)], layer.page === page, page.rotation == (layer.preserved ? layer.rotation : 0), page.bounds(for: .cropBox) == layer.shownBounds, document.index(for: page) != NSNotFound else { return nil }
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
        guard !readingLocked else { status = "请先切换到编辑模式";return }
        guard placingSignature == nil, let view = pdfView as? SignaturePlacing, let image = Self.decodePNG(item.png) else { return }
        do {
            moveSnapshot = try snapshot()
            movingSignature = (layer, item)
            let page = try rebake(layer, items: layer.items.filter { $0.id != item.id })
            let shown = layer.shownRect(item)
            let width = page.bounds(for: .cropBox).width
            tool = .select
            placingSignature = SignatureTemplate(name: "移动"+item.label, pdf: Data(), image: item.png, isPageImage:item.isPageImage)
            signatureWidth = min(0.8, max(0.08, Double(shown.width / max(1, width))))
            view.beginSignaturePlacement(image, widthFraction: signatureWidth, page: page, rect: shown)
            if item.isPageImage == true { updatePageImageSize() }
            changed()
            status = "拖动移动，拖角缩放；回车确认，Esc 放回原处"
        } catch {
            movingSignature = nil; moveSnapshot = nil
            self.error = error.localizedDescription
        }
    }

    /// Takes a placed signature off the page for good (undoable).
    func removePlacedSignature(_ item: PlacedSignature, in layer: SignatureLayer) {
        guard !readingLocked else { status = "请先切换到编辑模式";return }
        do {
            checkpoint()
            try rebake(layer, items: layer.items.filter { $0.id != item.id })
            changed()
            status = "已删除"+item.label+"（可撤销）"
        } catch { self.error = error.localizedDescription }
    }

    /// Redraws the page with exactly `items`, keeping the annotations that were added to it since.
    @discardableResult
    func rebake(_ layer: SignatureLayer, items: [PlacedSignature]) throws -> PDFPage {
        let old = layer.page
        let index = document.index(for: old)
        guard index != NSNotFound, let baseDocument = PDFDocument(data:layer.base),
              let basePage = baseDocument.page(at:0) else { throw FolioError(message:"页面已变化，无法再移动这个内容。") }
        let images = items.compactMap { item in Self.decodePNG(item.png).map { (image:$0,rect:item.rect) } }
        let extras = layer.preserved ? [] : old.annotations
        let page = try SignatureStamp.bake(images,onto:basePage,preserve:layer.preserved,extras:extras).unwrap("无法重绘页面")
        withExtendedLifetime(baseDocument) {}
        replacePage(old,with:page,at:index,preservingAnnotations:layer.preserved)
        signatureLayers[ObjectIdentifier(old)] = nil
        layer.page = page
        layer.items = items
        signatureLayers[ObjectIdentifier(page)] = layer
        return page
    }
}
