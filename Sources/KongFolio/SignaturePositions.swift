import AppKit
import CoreGraphics
import PDFKit

/// A remembered place for a signature: which page ("last page", "first page", "the page being read") and where on
/// it, as fractions of the page as it is shown, so the same template fits pages of any size and rotation.
struct SignaturePosition: Codable, Identifiable, Equatable {
    enum Page: String, Codable, CaseIterable {
        case current, first, last
        var label: String {
            switch self {
            case .current: return "当前页"
            case .first: return "首页"
            case .last: return "末页"
            }
        }
    }

    var id = UUID()
    var name: String
    var page: Page
    /// Centre of the signature, 0...1 from the left / from the bottom of the page as it is shown.
    var centerX: Double
    var centerY: Double
    /// Width of the signature as a fraction of the page width.
    var width: Double

    /// Ready-made places that are always offered; they are not stored.
    static let presets: [SignaturePosition] = [
        SignaturePosition(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "末页 · 右下", page: .last, centerX: 0.74, centerY: 0.12, width: 0.26),
        SignaturePosition(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "末页 · 左下", page: .last, centerX: 0.26, centerY: 0.12, width: 0.26),
        SignaturePosition(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "当前页 · 右下", page: .current, centerX: 0.74, centerY: 0.12, width: 0.26),
    ]

    static func isPreset(_ id: UUID) -> Bool { presets.contains { $0.id == id } }

    /// The page index this place refers to, or nil for an empty document.
    func pageIndex(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch page {
        case .current: return min(max(current, 0), count - 1)
        case .first: return 0
        case .last: return count - 1
        }
    }

    private static func uprightSize(of cropBox: CGRect, rotation: Int) -> CGSize {
        abs(rotation % 180) == 90 ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
    }

    /// The signature's rectangle in page coordinates for a picture with the given aspect ratio (width / height).
    func rect(aspect: CGFloat, cropBox: CGRect, rotation: Int) -> CGRect {
        let upright = Self.uprightSize(of: cropBox, rotation: rotation)
        let shown = SignatureStamp.fit(aspect: aspect, width: CGFloat(width) * upright.width,
                                       center: CGPoint(x: CGFloat(centerX) * upright.width, y: CGFloat(centerY) * upright.height),
                                       in: CGRect(origin: .zero, size: upright))
        let local = SignatureStamp.originalRect(shown, pageSize: cropBox.size, rotation: rotation)
        return local.offsetBy(dx: cropBox.minX, dy: cropBox.minY)
    }

    /// The place described by a rectangle in page coordinates.
    static func make(name: String, page: Page, rect: CGRect, cropBox: CGRect, rotation: Int) -> SignaturePosition {
        let upright = uprightSize(of: cropBox, rotation: rotation)
        let shown = SignatureStamp.uprightRect(rect.offsetBy(dx: -cropBox.minX, dy: -cropBox.minY), pageSize: cropBox.size, rotation: rotation)
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return SignaturePosition(name: name, page: page, centerX: clamp(shown.midX / max(upright.width, 1)),
                                 centerY: clamp(shown.midY / max(upright.height, 1)), width: Double(min(max(shown.width / max(upright.width, 1), 0.08), 0.8)))
    }
}

extension Workspace {
    private var positionsFile: URL { storage.appendingPathComponent("SignaturePositions.json") }

    func loadSignaturePositions() {
        signaturePositions = (try? JSONDecoder().decode([SignaturePosition].self, from: Data(contentsOf: positionsFile))) ?? []
    }

    /// Ready-made places followed by the ones the user saved.
    var allSignaturePositions: [SignaturePosition] { SignaturePosition.presets + signaturePositions }

    private func storePositions(_ updated: [SignaturePosition]) {
        report {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: positionsFile, options: .atomic)
            signaturePositions = updated
        }
    }

    /// Remembers where the signature being placed now is, as a place for `page` ("last page", ...).
    func rememberSignaturePosition(as page: SignaturePosition.Page) {
        guard placingSignature != nil, let placement = (pdfView as? SignaturePlacing)?.signaturePlacement() else { return }
        let number = signaturePositions.count + 1
        let position = SignaturePosition.make(name: "\(page.label) · 自定义 \(number)", page: page, rect: placement.rect,
                                              cropBox: placement.page.bounds(for: .cropBox), rotation: placement.page.rotation)
        storePositions(signaturePositions + [position])
        status = "已记住位置“\(position.name)”"
    }

    func removeSignaturePosition(_ id: UUID) {
        storePositions(signaturePositions.filter { $0.id != id })
    }

    /// Shows `template` at a remembered place, ready to be confirmed or nudged. Works while another place is being
    /// shown too: the stamp simply moves.
    func placeSignature(_ template: SignatureTemplate, at position: SignaturePosition) {
        guard let data = template.image,
              let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            beginPlacing(template)
            return
        }
        guard let view = pdfView as? SignaturePlacing, let index = position.pageIndex(current: selection, count: count),
              let page = document.page(at: index) else { return }
        if placingSignature == nil { beginPlacing(template) }
        let rect = position.rect(aspect: CGFloat(image.width) / CGFloat(max(image.height, 1)), cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        selection = index
        pdfView?.go(to: page)
        pdfView?.layoutDocumentView()
        signatureWidth = min(0.8, max(0.08, position.width))
        view.beginSignaturePlacement(image, widthFraction: signatureWidth, page: page, rect: rect)
        status = "已放到“\(position.name)”：可拖动微调；回车确认，Esc 取消"
    }
}
