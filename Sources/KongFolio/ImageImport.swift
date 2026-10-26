import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageImport {
    static func handles(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
    static func document(_ url: URL) throws -> PDFDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FolioError(message: "无法读取图片：\(url.lastPathComponent)") }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 3000 else { throw FolioError(message: "图片页数无效或超过 3000 页。") }
        let document = PDFDocument()
        // Preserve all TIFF pages; animated formats import the first frame only.
        let isTIFF = CGImageSourceGetType(source).map { UTType($0 as String)?.conforms(to: .tiff) == true } ?? false
        for index in 0..<(isTIFF ? count : 1) {
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 12000]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { throw FolioError(message: "无法转换图片第 \(index + 1) 页。") }
            document.insert(page, at: document.pageCount)
        }
        return document
    }
}
