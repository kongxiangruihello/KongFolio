import SwiftUI
import PDFKit

extension Workspace {
    func selectAnnotation(_ annotation: PDFAnnotation?) {
        selectedAnnotation = annotation
        if let annotation {
            if let page = annotation.page { selection = document.index(for: page) }
            note = annotation.contents ?? ""; annotationColor = Color(nsColor: annotation.fontColor ?? annotation.color)
        }
    }
    func updateAnnotation() {
        guard let annotation = selectedAnnotation else { return }
        checkpoint(); annotation.contents = note
        if annotation.type == "FreeText" { annotation.fontColor = NSColor(annotationColor) }
        else { annotation.color = NSColor(annotationColor).withAlphaComponent(annotation.type == "Highlight" ? 0.4 : 1) }
        edited()
    }
    func deleteAnnotation() {
        guard let annotation = selectedAnnotation, let page = annotation.page else { return }
        checkpoint(); page.removeAnnotation(annotation); selectedAnnotation = nil; edited()
    }
    func resizeAnnotation(_ factor: CGFloat) {
        guard let annotation = selectedAnnotation else { return }
        checkpoint(); AnnotationGeometry.scale(annotation, by: factor); edited()
    }
    func saveSignature() {
        guard let page else { return }
        let strokes = page.annotations.filter { $0.type == "Ink" && $0.userName == "KongFolio Signature" }
        guard !strokes.isEmpty else { error = "请先使用签名工具手写签名。将保存当前页的所有签名笔画。"; return }
        let doc = PDFDocument(); let blank = PDFPage(); blank.setBounds(page.bounds(for: .mediaBox), for: .mediaBox); doc.insert(blank, at: 0)
        for stroke in strokes { if let copy = stroke.copy() as? PDFAnnotation { blank.addAnnotation(copy) } }
        guard let data = doc.dataRepresentation() else { return }
        let template = SignatureTemplate(name: "签名 \(signatures.count + 1)", pdf: data)
        report {
            let updated = signatures + [template]
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: storage.appendingPathComponent("Signatures.json"), options: .atomic)
            signatures = updated; status = "签名已保存在本机"
        }
    }
    func insertSignature(_ template: SignatureTemplate) {
        guard let page, let source = PDFDocument(data: template.pdf), let original = source.page(at: 0) else { return }
        let strokes = original.annotations.filter { $0.type == "Ink" }
        guard !strokes.isEmpty else { return }
        let union = strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        let target = page.bounds(for: .cropBox)
        let factor = min(1, target.width * 0.4 / max(1, union.width))
        checkpoint()
        for stroke in strokes {
            guard let copy = stroke.copy() as? PDFAnnotation else { continue }
            AnnotationGeometry.scale(copy, by: factor)
            copy.bounds.origin = CGPoint(x: target.midX - union.width * factor / 2 + (stroke.bounds.minX - union.minX) * factor, y: target.midY + (stroke.bounds.minY - union.minY) * factor)
            page.addAnnotation(copy)
        }
        edited(); status = "签名已插入页面中央，可用编辑标注工具移动"
    }
    func removeSignature(_ id: UUID) {
        report {
            let updated = signatures.filter { $0.id != id }
            try JSONEncoder().encode(updated).write(to: storage.appendingPathComponent("Signatures.json"), options: .atomic); signatures = updated
        }
    }
}
enum AnnotationGeometry {
    static func scale(_ annotation: PDFAnnotation, by factor: CGFloat) {
        let old = annotation.bounds
        if annotation.type == "Ink", let paths = annotation.paths {
            for path in paths { annotation.remove(path) }
            for path in paths {
                let copy = path.copy() as! NSBezierPath
                var transform = AffineTransform(); transform.scale(factor); copy.transform(using: transform); annotation.add(copy)
            }
        }
        if annotation.type == "Line" {
            annotation.startPoint = CGPoint(x: annotation.startPoint.x * factor, y: annotation.startPoint.y * factor)
            annotation.endPoint = CGPoint(x: annotation.endPoint.x * factor, y: annotation.endPoint.y * factor)
        }
        if annotation.type == "FreeText", let font = annotation.font { annotation.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * factor) }
        if ["Highlight", "Underline", "StrikeOut"].contains(annotation.type ?? ""), let points = annotation.quadrilateralPoints, !points.isEmpty { annotation.quadrilateralPoints = points.map { NSValue(point: CGPoint(x: $0.pointValue.x * factor, y: $0.pointValue.y * factor)) } }
        annotation.bounds = CGRect(origin: old.origin, size: CGSize(width: max(4, old.width * factor), height: max(4, old.height * factor)))
    }
}
