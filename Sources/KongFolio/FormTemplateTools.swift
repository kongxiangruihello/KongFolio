import AppKit
import PDFKit
import Vision

struct FormFieldCandidate: Identifiable {
    var id = UUID()
    var kind: FormTemplateField.Kind
    var rect: CGRect
}
enum FormTemplateTools {
    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: min(1-rect.width,max(0,rect.minX+dx)), y: min(1-rect.height,max(0,rect.minY+dy)), width: rect.width, height: rect.height)
    }
    static func resized(_ rect: CGRect, dw: CGFloat, dh: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: min(1-rect.minX,max(0.01,rect.width+dw)), height: min(1-rect.minY,max(0.01,rect.height+dh)))
    }
    enum Alignment: String, CaseIterable { case left = "左对齐", top = "上对齐", width = "等宽", height = "等高" }
    static func align(_ template: inout FormTemplate, ids: Set<UUID>, mode: Alignment) throws {
        guard let reference = template.fields.first(where: { ids.contains($0.id) }), ids.count >= 2 else { throw FolioError(message: "请至少选择两个字段") }
        var result = template
        for i in result.fields.indices where ids.contains(result.fields[i].id) {
            switch mode {
            case .left: result.fields[i].rect.origin.x = reference.rect.minX
            case .top: result.fields[i].rect.origin.y = reference.rect.minY
            case .width: result.fields[i].rect.size.width = reference.rect.width
            case .height: result.fields[i].rect.size.height = reference.rect.height
            }
        }
        try result.validate(); template = result
    }
    static func candidates(rectangles: [CGRect]) -> [FormFieldCandidate] {
        var result: [FormFieldCandidate] = []
        for rect in rectangles.sorted(by: { abs($0.minY-$1.minY) > 0.015 ? $0.minY < $1.minY : $0.minX < $1.minX }) {
            guard TableGrid.validRect(rect), rect.width < 0.75, rect.height < 0.14, rect.height >= 0.008, rect.width >= 0.012 else { continue }
            guard !result.contains(where: { let overlap = $0.rect.intersection(rect); return !overlap.isNull && overlap.width * overlap.height > min($0.rect.width * $0.rect.height,rect.width * rect.height) * 0.75 }) else { continue }
            let ratio = rect.width / rect.height
            result.append(FormFieldCandidate(kind: (0.65...1.5).contains(ratio) ? .check : .text, rect: rect))
            if result.count == 200 { break }
        }
        return result
    }
    static func detect(_ image: CGImage) throws -> [FormFieldCandidate] {
        try Task.checkCancellation()
        let request = VNDetectRectanglesRequest(); request.maximumObservations = 200; request.minimumConfidence = 0.45; request.minimumAspectRatio = 0.08; request.minimumSize = 0.008; request.quadratureTolerance = 12
        try VNImageRequestHandler(cgImage: image).perform([request]); try Task.checkCancellation()
        var boxes = (request.results ?? []).map { result in let r = result.boundingBox; return CGRect(x:r.minX,y:1-r.maxY,width:r.width,height:r.height) }
        // Blank underline candidates: a dark horizontal rule with mostly white space immediately above.
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 255, count: w*h)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image,in:CGRect(x:0,y:0,width:w,height:h)); return true
        }
        if drew, w > 80, h > 80 {
            var lastY = -100
            for y in 12..<h-4 {
                if y % 30 == 0 { try Task.checkCancellation() }
                guard y-lastY > 8 else { continue }
                var x = 0
                while x < w {
                    if bytes[y*w+x] < 90 {
                        let start=x; while x < w, bytes[y*w+x] < 130 { x += 1 }; let length=x-start
                        if length >= max(40,w/22), length < w*3/4 {
                            let height=max(12,h/35), top=max(0,y-height); var ink=0, samples=0
                            for yy in stride(from:top,to:max(top+1,y-3),by:3) { for xx in stride(from:start+3,to:max(start+4,x-3),by:3) { samples += 1; if bytes[yy*w+xx] < 130 { ink += 1 } } }
                            if samples > 0, Double(ink)/Double(samples) < 0.04 { boxes.append(CGRect(x:Double(start)/Double(w),y:Double(top)/Double(h),width:Double(length)/Double(w),height:Double(height)/Double(h))); lastY=y }
                        }
                    } else { x += 1 }
                }
            }
        }
        return candidates(rectangles:boxes)
    }
}
extension Workspace {
    func applyFormTemplate(_ template: FormTemplate, pages: [Int], from expectedRevision: UUID) throws {
        try applyTemplate(template, pages: pages, revision: expectedRevision, pageNames: pages.count > 1)
    }
    func applyTemplate(_ template: FormTemplate, pages: [Int], revision expectedRevision: UUID, pageNames: Bool) throws {
        guard !busy, revision == expectedRevision, !pages.isEmpty, Set(pages).count == pages.count, pages.allSatisfy({ (0..<count).contains($0) }), pages.count * template.fields.count <= 5000 else { throw FolioError(message: "文档已变化、页码无效或字段超过 5000 个，请重新核对") }
        try template.validate(); guard !template.fields.isEmpty else { throw FolioError(message: "请先添加字段") }
        let names = Set(PDFForms.fields(document).map(\.name))
        var additions: [(Int, PDFAnnotation)] = [], addedNames = Set<String>()
        for index in pages {
            let page = document.page(at:index)!; try template.validate(for:page)
            for field in template.fields {
                let fullName = (template.name + " / " + field.name + (pageNames ? " · 第 \(index+1) 页" : "")).replacingOccurrences(of:".",with:"．")
                guard !names.contains(fullName), addedNames.insert(fullName).inserted else { throw FolioError(message:"第 \(index+1) 页存在同名模板字段，请直接填写或更换名称") }
                let rect = OrderedText.pageRect(forFraction:CGRect(x:field.rect.minX,y:1-field.rect.maxY,width:field.rect.width,height:field.rect.height),cropBox:page.bounds(for:.cropBox),rotation:page.rotation)
                let annotation=PDFAnnotation(bounds:rect,forType:.widget,withProperties:nil), border=PDFBorder(); border.lineWidth=0.6;annotation.border=border;annotation.color = .darkGray
                if field.kind == .text { annotation.widgetFieldType = .text;annotation.font = .systemFont(ofSize:min(14,max(8,rect.height*0.55)));annotation.fontColor = .black;annotation.widgetStringValue="" }
                else { annotation.widgetFieldType = .button;annotation.widgetControlType = .checkBoxControl;annotation.buttonWidgetStateString="Yes";annotation.buttonWidgetState = .offState }
                annotation.fieldName=fullName; additions.append((index,annotation))
            }
        }
        checkpoint(); for (index,annotation) in additions { document.page(at:index)!.addAnnotation(annotation) };edited(pages:Set(pages));pdfView?.needsDisplay=true
        status="已向 \(pages.count) 页添加 \(additions.count) 个字段，可统一填写并保存"
    }
}
