import AppKit
import PDFKit

struct PageInspectionCandidate: Identifiable {
    enum Kind { case blank, duplicate }
    var page: Int
    var kind: Kind
    var original: Int?
    var id: Int { page }
    var title: String { kind == .blank ? "第 \(page + 1) 页 · 疑似空白" : "第 \(page + 1) 页 · 与第 \((original ?? 0) + 1) 页疑似重复" }
}

enum PageInspection {
    /// Compares rendered appearances, not object IDs; annotations/links and any nonempty text protect a blank candidate.
    static func scan(_ data: Data) throws -> [PageInspectionCandidate] {
        guard let document = PDFDocument(data: data), !document.isLocked else { throw FolioError(message: "无法检查这个 PDF") }
        var seen: [String: Int] = [:], result: [PageInspectionCandidate] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index), page.annotations.isEmpty else { return }
                let picture = try DocumentServices.render(page, maxDimension: 512)
                let width = picture.width, height = picture.height
                guard width > 0, height > 0 else { return }
                var pixels = [UInt8](repeating: 255, count: width * height * 4)
                let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
                }
                guard drawn else { throw FolioError(message: "无法检查第 \(index + 1) 页") }
                var dark = 0
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    if min(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 240 { dark += 1 }
                }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty, Double(dark) / Double(width * height) < 0.0005 {
                    result.append(PageInspectionCandidate(page: index, kind: .blank)); return
                }
                // Text is part of the identity: invisible OCR records must not be discarded just because pictures match.
                let box = page.bounds(for: .cropBox)
                let context = "\(width)|\(height)|\(box.width)|\(box.height)|\(page.rotation)|\(text)"
                let digest = OCRPageCache.digest(Data(pixels) + Data(context.utf8))
                if let original = seen[digest] { result.append(PageInspectionCandidate(page: index, kind: .duplicate, original: original)) }
                else { seen[digest] = index }
            }
        }
        return result
    }
}

extension Workspace {
    @discardableResult func removeInspectedPages(_ pages: Set<Int>, snapshot: Data) -> Bool {
        guard !busy, !pages.isEmpty, pages.allSatisfy({ (0..<count).contains($0) }), pages.count < count else { error = "至少保留一页，请重新选择"; return false }
        do {
            guard try pdfData() == snapshot else { throw FolioError(message: "文档在检查后已有变化，请重新检查后删除") }
            let keep = (0..<count).filter { !pages.contains($0) }
            checkpoint(); rebuild(order: keep, selected: [0]); status = "已删除 \(pages.count) 页，⌘Z 可撤销"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
