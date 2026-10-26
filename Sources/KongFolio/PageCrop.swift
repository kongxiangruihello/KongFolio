import AppKit
import CoreGraphics
import PDFKit

/// How much to cut from each side of a page, as fractions of the page as it is shown (so rotated pages and pages of
/// different sizes can share one setting).
struct CropMargins: Equatable {
    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0

    static let zero = CropMargins()
    static let limit = 0.45

    var isZero: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }

    /// Every side within 0...0.45 and opposite sides leaving at least 10 % of the page.
    var clamped: CropMargins {
        func side(_ value: Double) -> Double { min(max(value.isFinite ? value : 0, 0), Self.limit) }
        var result = CropMargins(left: side(left), right: side(right), top: side(top), bottom: side(bottom))
        if result.left + result.right > 0.9 { let scale = 0.9 / (result.left + result.right); result.left *= scale; result.right *= scale }
        if result.top + result.bottom > 0.9 { let scale = 0.9 / (result.top + result.bottom); result.top *= scale; result.bottom *= scale }
        return result
    }
}

/// Which pages a crop applies to.
enum CropScope: String, CaseIterable, Identifiable {
    case all = "全部页"
    case selected = "选中的页"
    var id: String { rawValue }
}

enum PageCrop {
    /// The crop box (page coordinates) that leaves `margins` cut from a page whose media box is `mediaBox`.
    static func cropBox(mediaBox: CGRect, rotation: Int, margins: CropMargins) -> CGRect {
        let m = margins.clamped
        let quarterTurn = abs(rotation % 180) == 90
        let width = quarterTurn ? mediaBox.height : mediaBox.width
        let height = quarterTurn ? mediaBox.width : mediaBox.height
        let shown = CGRect(x: m.left * width, y: m.bottom * height, width: width * (1 - m.left - m.right), height: height * (1 - m.top - m.bottom))
        let local = SignatureStamp.originalRect(shown, pageSize: mediaBox.size, rotation: rotation)
        return local.offsetBy(dx: mediaBox.minX, dy: mediaBox.minY)
    }

    /// The margins that a crop box leaves (the reverse of `cropBox`).
    static func margins(of cropBox: CGRect, mediaBox: CGRect, rotation: Int) -> CropMargins {
        let quarterTurn = abs(rotation % 180) == 90
        let width = quarterTurn ? mediaBox.height : mediaBox.width
        let height = quarterTurn ? mediaBox.width : mediaBox.height
        guard width > 0, height > 0 else { return .zero }
        let shown = SignatureStamp.uprightRect(cropBox.offsetBy(dx: -mediaBox.minX, dy: -mediaBox.minY), pageSize: mediaBox.size, rotation: rotation)
        return CropMargins(left: Double(shown.minX / width), right: Double((width - shown.maxX) / width),
                           top: Double((height - shown.maxY) / height), bottom: Double(shown.minY / height)).clamped
    }

    /// A rectangle given as fractions of the visible area under the `old` cut, as fractions under the `new` cut
    /// (both origin bottom-left, like Vision's boxes), so recognised regions stay on their characters.
    static func remap(_ box: CGRect, from old: CropMargins, to new: CropMargins) -> CGRect {
        let oldWidth = 1 - old.left - old.right, oldHeight = 1 - old.top - old.bottom
        let newWidth = 1 - new.left - new.right, newHeight = 1 - new.top - new.bottom
        guard oldWidth > 0, oldHeight > 0, newWidth > 0, newHeight > 0 else { return box }
        let x = (old.left + Double(box.minX) * oldWidth - new.left) / newWidth
        let y = (old.bottom + Double(box.minY) * oldHeight - new.bottom) / newHeight
        return CGRect(x: x, y: y, width: Double(box.width) * oldWidth / newWidth, height: Double(box.height) * oldHeight / newHeight)
    }

    /// Whether the page at `index` counts as an odd page of the book (the first page is page 1).
    static func isOddPage(_ index: Int) -> Bool { index % 2 == 0 }
}

/// Finds where the printed area of a scanned page is.
enum ContentBounds {
    /// Draws the page, as it is shown, into a grey bitmap `width` pixels wide (white = 255).
    static func render(_ page: PDFPage, width: Int = 320, box displayBox: PDFDisplayBox = .mediaBox) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard page.pageRef != nil else { return nil }
        let box = page.bounds(for: displayBox)
        let quarterTurn = abs(page.rotation % 180) == 90
        let pageWidth = quarterTurn ? box.height : box.width, pageHeight = quarterTurn ? box.width : box.height
        guard pageWidth > 0, pageHeight > 0 else { return nil }
        let height = max(8, Int(min(4096,(CGFloat(width) * pageHeight / pageWidth).rounded())))
        // PDFKit's own thumbnail draws the page upright, whatever its rotation or boxes.
        guard let picture = page.thumbnail(of: CGSize(width: width, height: height), for: displayBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .medium
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    /// The margins around the printed area of a grey bitmap (row 0 is the top), or nil for an empty page.
    /// "Ink" is anything clearly darker than the paper; rows and columns that are dark almost all the way across
    /// (scanner edges, binding shadows) are ignored, and so are specks smaller than a few pixels.
    static func margins(pixels: [UInt8], width: Int, height: Int) -> CropMargins? {
        guard width >= 8, height >= 8, pixels.count >= width * height else { return nil }
        // Paper brightness: the 90th percentile of all pixels.
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels[0..<(width * height)] { histogram[Int(value)] += 1 }
        var seen = 0, paper = 255
        for level in 0..<256 {
            seen += histogram[level]
            if seen * 10 >= width * height * 9 { paper = level; break }
        }
        let threshold = max(paper - 60, 0)
        func dark(_ x: Int, _ y: Int) -> Bool { Int(pixels[y * width + x]) < threshold }
        var rowInk = [Int](repeating: 0, count: height), columnInk = [Int](repeating: 0, count: width)
        for y in 0..<height { for x in 0..<width where dark(x, y) { rowInk[y] += 1; columnInk[x] += 1 } }
        // Rows and columns that are dark almost all the way across are scanner edges or binding shadows, not print.
        let edgeRows = rowInk.map { $0 * 100 > width * 85 }, edgeColumns = columnInk.map { $0 * 100 > height * 85 }
        rowInk = [Int](repeating: 0, count: height)
        columnInk = [Int](repeating: 0, count: width)
        for y in 0..<height where !edgeRows[y] { for x in 0..<width where !edgeColumns[x] && dark(x, y) { rowInk[y] += 1; columnInk[x] += 1 } }
        func contentful(_ count: Int, span: Int) -> Bool { count >= max(2, span / 250) }
        guard let top = (0..<height).first(where: { contentful(rowInk[$0], span: width) }),
              let bottom = (0..<height).last(where: { contentful(rowInk[$0], span: width) }),
              let left = (0..<width).first(where: { contentful(columnInk[$0], span: height) }),
              let right = (0..<width).last(where: { contentful(columnInk[$0], span: height) }),
              bottom > top, right > left else { return nil }
        return CropMargins(left: Double(left) / Double(width), right: Double(width - 1 - right) / Double(width),
                           top: Double(top) / Double(height), bottom: Double(height - 1 - bottom) / Double(height))
    }

    /// One setting for a group of pages: on 90 % of the pages nothing printed is cut, and `padding` is kept around it.
    static func common(of samples: [CropMargins], padding: Double = 0.012) -> CropMargins {
        guard !samples.isEmpty else { return .zero }
        func pick(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return max(0, sorted[Int(Double(sorted.count - 1) * 0.1)] - padding)
        }
        return CropMargins(left: pick(samples.map(\.left)), right: pick(samples.map(\.right)),
                           top: pick(samples.map(\.top)), bottom: pick(samples.map(\.bottom))).clamped
    }
}

extension Workspace {
    /// The pages a crop would change, in order.
    var cropTargets: [Int] { cropScope == .all ? Array(0..<count) : effectivePages }

    func openCrop() {
        guard count > 0 else { return }
        if let page = document.page(at: selection) {
            let current = PageCrop.margins(of: page.bounds(for: .cropBox), mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
            if !current.isZero, cropOdd.isZero, cropEven.isZero { cropOdd = current; cropEven = current }
        }
        showCrop = true
    }

    /// Cuts the chosen pages. The pages themselves are untouched (only the visible area changes), so the cut can be
    /// undone, or reset with `resetCrop`.
    func applyCrop() {
        guard count > 0 else { return }
        let targets = cropTargets
        guard !targets.isEmpty else { return }
        checkpoint()
        for index in targets {
            guard let page = document.page(at: index) else { continue }
            let margins = (cropSeparate && !PageCrop.isOddPage(index) ? cropEven : cropOdd).clamped
            let media = page.bounds(for: .mediaBox)
            let before = PageCrop.margins(of: page.bounds(for: .cropBox), mediaBox: media, rotation: page.rotation)
            page.setBounds(PageCrop.cropBox(mediaBox: media, rotation: page.rotation, margins: margins), for: .cropBox)
            moveRegions(of: index, from: before, to: margins)
        }
        changed()
        showCrop = false
        status = "已裁边 \(targets.count) 页（可撤销）"
    }

    /// Shows the whole page again.
    func resetCrop() {
        guard count > 0 else { return }
        let targets = cropTargets
        checkpoint()
        for index in targets {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let before = PageCrop.margins(of: page.bounds(for: .cropBox), mediaBox: media, rotation: page.rotation)
            page.setBounds(media, for: .cropBox)
            moveRegions(of: index, from: before, to: .zero)
        }
        changed()
        showCrop = false
        status = "已恢复 \(targets.count) 页的完整页面"
    }

    /// The margins a page has right now.
    func currentCrop(of index: Int) -> CropMargins {
        guard let page = document.page(at: index) else { return .zero }
        return PageCrop.margins(of: page.bounds(for: .cropBox), mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
    }

    /// Switches the sheet to one page at a time, starting from what the page has now.
    func setCropSingle(_ on: Bool) {
        cropSingle = on
        if on { cropPage = currentCrop(of: selection) }
    }

    /// Moves the preview to a neighbouring page and loads that page's own cut into the sliders.
    func stepCropPage(_ delta: Int) {
        let next = min(max(selection + delta, 0), count - 1)
        guard next != selection else { return }
        selection = next
        if cropSingle { cropPage = currentCrop(of: next) }
    }

    /// Cuts only the page being previewed and leaves the sheet open for the next one.
    func applyCropToCurrentPage() {
        guard count > 0, let page = document.page(at: selection) else { return }
        let margins = cropPage.clamped
        let before = currentCrop(of: selection)
        guard before != margins else { return }
        checkpoint()
        page.setBounds(PageCrop.cropBox(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation, margins: margins), for: .cropBox)
        moveRegions(of: selection, from: before, to: margins)
        changed()
        status = "已裁第 \(selection + 1) 页（可撤销）"
    }

    /// Keeps the recognised regions of a page on their characters when the visible area changes.
    private func moveRegions(of index: Int, from old: CropMargins, to new: CropMargins) {
        guard old != new else { return }
        updateMeta(index) { meta in
            meta.ocrRegions = meta.ocrRegions?.map { line in
                var moved = line
                moved.box = PageCrop.remap(line.box, from: old, to: new)
                return moved
            }
        }
    }

    /// Proposes margins for the page being previewed alone.
    func detectCropPage() {
        guard let page = document.page(at: selection), let bitmap = ContentBounds.render(page),
              let found = ContentBounds.margins(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height) else {
            cropMessage = "没有在这一页上找到可识别的内容。"
            return
        }
        cropPage = found
        cropMessage = "已检测本页内容边界，请看预览后再点“裁这一页”。"
    }

    /// Looks at the pages to cut and proposes margins (one setting for odd pages, one for even pages).
    func detectCrop() {
        guard count > 0, !cropDetecting, let data = try? pdfData() else { return }
        let targets = cropTargets
        cropDetecting = true
        cropMessage = ""
        Task {
            let result = await Task.detached { () -> (odd: CropMargins, even: CropMargins, counted: Int)? in
                guard let copy = PDFDocument(data: data) else { return nil }
                var odd: [CropMargins] = [], even: [CropMargins] = []
                for index in targets {
                    guard let page = copy.page(at: index), let bitmap = ContentBounds.render(page),
                          let found = ContentBounds.margins(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height) else { continue }
                    if PageCrop.isOddPage(index) { odd.append(found) } else { even.append(found) }
                }
                guard !odd.isEmpty || !even.isEmpty else { return nil }
                let oddCommon = ContentBounds.common(of: odd), evenCommon = ContentBounds.common(of: even)
                return (odd.isEmpty ? evenCommon : oddCommon, even.isEmpty ? oddCommon : evenCommon, odd.count + even.count)
            }.value
            cropDetecting = false
            guard let result else { cropMessage = "没有在这些页面上找到可识别的内容。"; return }
            cropOdd = result.odd
            cropEven = result.even
            cropSeparate = true
            cropMessage = "已根据 \(result.counted) 页自动检测；奇偶页分别设置，请看预览后再应用。"
        }
    }
}
