import AppKit
import PDFKit
import Vision

struct ScanIssue: Identifiable, Equatable {
    var page: Int
    var reasons: [String]
    var angle: Double
    var id: Int { page }
}

enum ScanProcessing {
    static func splitBoxes(_ page: PDFPage, fraction: Double) -> [CGRect] {
        let crop = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let shown = CGSize(width: rotated ? crop.height : crop.width, height: rotated ? crop.width : crop.height)
        let cut = min(0.8, max(0.2, fraction)) * shown.width
        return [CGRect(x: 0, y: 0, width: cut, height: shown.height), CGRect(x: cut, y: 0, width: shown.width - cut, height: shown.height)].map {
            SignatureStamp.originalRect($0, pageSize: crop.size, rotation: page.rotation).offsetBy(dx: crop.minX, dy: crop.minY)
        }
    }
    static func halves(_ page: PDFPage, fraction: Double, rightFirst: Bool) throws -> [PDFPage] {
        let boxes = splitBoxes(page, fraction: fraction)
        return try (rightFirst ? boxes.reversed() : boxes).map { box in
            guard let copy = page.copy() as? PDFPage else { throw FolioError(message: "无法复制跨页扫描页") }
            copy.setBounds(box, for: .cropBox)
            // Remove annotations entirely outside this half; marks crossing the fold remain clipped to the page.
            for annotation in copy.annotations where !annotation.bounds.intersects(box) { copy.removeAnnotation(annotation) }
            return copy
        }
    }
    /// Return the median text baseline angle in degrees; reject large rotations and insufficient evidence.
    static func baselineAngle(_ observations: [(CGPoint, CGPoint)], size: CGSize) -> Double {
        let angles = observations.compactMap { a, b -> Double? in
            let dx = Double((b.x-a.x) * size.width), dy = Double((b.y-a.y) * size.height)
            guard abs(dx) > 20 else { return nil }
            let angle = atan2(dy, dx) * 180 / .pi
            return abs(angle) <= 7.5 ? angle : nil
        }.sorted()
        guard angles.count >= 3 else { return 0 }
        return angles[angles.count / 2]
    }
    static func angle(_ page: PDFPage) throws -> Double {
        let image = try DocumentServices.render(page, maxDimension: 1600)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).filter { $0.confidence > 0.3 }
        return baselineAngle(lines.map { ($0.topLeft, $0.topRight) }, size: CGSize(width: image.width, height: image.height))
    }
    /// Vector redraw: expand the media box so straightening cannot cut off the corners.
    static func straightened(_ page: PDFPage, angle: Double) throws -> PDFPage {
        guard angle.isFinite, abs(angle) <= 7.5 else { throw FolioError(message: "纠偏角度必须在 ±7.5° 内") }
        guard let reference = page.pageRef else { throw FolioError(message: "无法读取页面") }
        let crop = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let w = rotated ? crop.height : crop.width, h = rotated ? crop.width : crop.height
        let radians = CGFloat(-angle * .pi / 180)
        var bounds = CGRect(x: 0, y: 0, width: abs(w*cos(radians))+abs(h*sin(radians)), height: abs(w*sin(radians))+abs(h*cos(radians)))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw FolioError(message: "无法创建纠偏页面") }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(bounds)
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: radians)
        ctx.translateBy(x: -w/2, y: -h/2)
        ctx.concatenate(reference.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(reference)
        for annotation in page.annotations { annotation.draw(with: .cropBox, in: ctx) }
        ctx.endPDFPage(); ctx.closePDF()
        guard let output = PDFDocument(data: data as Data)?.page(at: 0) else { throw FolioError(message: "纠偏失败") }
        return output
    }
    static func inspect(_ data: Data, pages: [Int]) throws -> [ScanIssue] {
        guard let doc = PDFDocument(data: data) else { throw FolioError(message: "无法读取文档") }
        var issues: [ScanIssue] = []
        for index in pages {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = doc.page(at: index) else { return }
                let image = try DocumentServices.render(page, maxDimension: 500)
                let pixels = SignatureImage.pixels(of: image, maxDimension: 300)
                var reasons: [String] = []
                if let pixels {
                    var ink = 0
                    for p in stride(from: 0, to: pixels.data.count, by: 4) {
                        if min(pixels.data[p], pixels.data[p+1], pixels.data[p+2]) < 180 { ink += 1 }
                    }
                    if Double(ink) / Double(pixels.width * pixels.height) < 0.001 { reasons.append("疑似空白页") }
                }
                if image.width > image.height * 3 / 2 { reasons.append("横向页：检查跨页扫描或方向") }
                if BackgroundJobs.textCharacterCount(page) < 5 { reasons.append("文字层过少：可检查或重新 OCR") }
                let angle = try angle(page)
                if abs(angle) >= 0.4 { reasons.append(String(format: "文字倾斜约 %.1f°", angle)) }
                if !reasons.isEmpty { issues.append(ScanIssue(page: index, reasons: reasons, angle: angle)) }
            }
        }
        return issues
    }
}

extension Workspace {
    func splitScannedPages(_ pages: [Int], fraction: Double, rightFirst: Bool) throws {
        guard !busy, !pages.isEmpty, pages.allSatisfy({ (0..<count).contains($0) }) else { return }
        guard fraction.isFinite, (0.2...0.8).contains(fraction) else { throw FolioError(message: "中缝比例必须在 20%–80% 之间") }
        // Work from committed bytes so in-memory crop/rotation edits are respected by PDFKit.
        let source = try PDFDocument(data: pdfData()).unwrap("无法读取文档")
        alignMeta()
        let oldMeta = pageMeta, chosen = Set(pages), output = PDFDocument()
        var metadata: [PageMeta] = [], first: [Int: Int] = [:], newSelection = Set<Int>()
        for index in 0..<source.pageCount {
            first[index] = output.pageCount
            let page = try source.page(at: index).unwrap("无法读取页面")
            if chosen.contains(index) {
                let pieces = try ScanProcessing.halves(page, fraction: fraction, rightFirst: rightFirst)
                for (half, piece) in pieces.enumerated() {
                    var meta = oldMeta[index]
                    let isRight = rightFirst ? half == 0 : half == 1
                    let start = isRight ? fraction : 0, width = isRight ? 1-fraction : fraction
                    meta.ocrRegions = meta.ocrRegions?.compactMap { line in
                        guard Double(line.box.midX) >= start, Double(line.box.midX) < start+width else { return nil }
                        var result = line
                        result.box = CGRect(x: (Double(line.box.minX)-start)/width, y: line.box.minY, width: Double(line.box.width)/width, height: line.box.height).intersection(CGRect(x:0,y:0,width:1,height:1))
                        return result
                    }
                    if let original = meta.ocrOriginal, let originalPage = PDFDocument(data: original)?.page(at: 0) {
                        let holder = PDFDocument(); holder.insert(try ScanProcessing.halves(originalPage, fraction: fraction, rightFirst: rightFirst)[half], at: 0)
                        meta.ocrOriginal = holder.dataRepresentation()
                    }
                    newSelection.insert(output.pageCount); output.insert(piece, at: output.pageCount); metadata.append(meta)
                }
            } else { output.insert(page, at: output.pageCount); metadata.append(oldMeta[index]) }
        }
        checkpoint()
        bookmarks = bookmarks.compactMap { b in first[b.page].map { var c = b; c.page = $0; return c } }
        outlineEntries = outlineEntries.compactMap { e in first[e.page].map { var c = e; c.page = $0; return c } }
        document = output; pageMeta = metadata
        selectedPages = newSelection; selection = newSelection.min() ?? 0
        ReadingServices.applyOutline(outlineEntries, to: document)
        readingPoint = nil; navigationToken = UUID()
        changed(); status = "已切分 \(pages.count) 个跨页扫描页，可撤销"
    }
    func applyStraightened(_ bytes: Data, pages: Set<Int>) throws {
        guard let doc = PDFDocument(data: bytes), doc.pageCount == count else { throw FolioError(message: "纠偏输出不完整") }
        checkpoint()
        document = doc
        for page in pages { updateMeta(page) { $0.ocrRegions = nil; $0.ocrOriginal = nil } }
        ReadingServices.applyOutline(outlineEntries, to: document)
        readingPoint = nil; navigationToken = UUID()
        changed(); status = "已完成 \(pages.count) 页纠偏；原页可通过撤销恢复"
    }
}
