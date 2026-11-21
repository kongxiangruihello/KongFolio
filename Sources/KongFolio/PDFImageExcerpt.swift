import AppKit
import PDFKit

enum PDFImageExcerpt {
    /// Converts an unrotated PDF crop-box rectangle into upright top-left image coordinates.
    static func pixelBounds(for rect: CGRect, cropBox: CGRect, rotation: Int, imageSize: CGSize) -> CGRect? {
        let clipped = rect.standardized.intersection(cropBox)
        guard !clipped.isNull, !clipped.isEmpty, !clipped.isInfinite,
              cropBox.width > 0, cropBox.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let x = (clipped.minX - cropBox.minX) / cropBox.width
        let y = (clipped.minY - cropBox.minY) / cropBox.height
        let width = clipped.width / cropBox.width
        let height = clipped.height / cropBox.height
        let normalized: CGRect
        switch (rotation % 360 + 360) % 360 {
        case 90: normalized = CGRect(x: y, y: x, width: height, height: width)
        case 180: normalized = CGRect(x: 1 - x - width, y: y, width: width, height: height)
        case 270: normalized = CGRect(x: 1 - y - height, y: 1 - x - width, width: height, height: width)
        default: normalized = CGRect(x: x, y: 1 - y - height, width: width, height: height)
        }
        return normalized.applying(CGAffineTransform(scaleX: imageSize.width, y: imageSize.height))
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func png(for rect: CGRect, on page: PDFPage) throws -> Data {
        let image = try DocumentServices.render(page, maxDimension: 3200)
        guard let pixelRect = pixelBounds(for: rect, cropBox: page.bounds(for: .cropBox), rotation: page.rotation,
                                          imageSize: CGSize(width: image.width, height: image.height)),
              let crop = image.cropping(to: pixelRect), let data = SignatureImage.pngData(crop) else {
            throw FolioError(message: "无法生成图片摘录，请重新框选。")
        }
        return data
    }
}
