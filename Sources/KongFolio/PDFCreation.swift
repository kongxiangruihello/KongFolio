import AppKit
import PDFKit
import CoreText

struct PDFCreationColor: Codable, Equatable {
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: Double = 1, green: Double = 1, blue: Double = 1) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
}

enum PDFPaperPattern: String, Codable, CaseIterable, Identifiable {
    case blank = "空白", ruled = "横线", grid = "方格", dotted = "点阵", cornell = "康奈尔笔记", music = "五线谱"
    var id: String { rawValue }
}

enum PDFPaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4", a3 = "A3", a5 = "A5", b5 = "B5", letter = "Letter", legal = "Legal"
    case wide = "16:9", standard = "4:3", custom = "自定义"
    var id: String { rawValue }
    var points: CGSize? {
        let mm = 72.0 / 25.4
        switch self {
        case .a4: return CGSize(width: 210 * mm, height: 297 * mm)
        case .a3: return CGSize(width: 297 * mm, height: 420 * mm)
        case .a5: return CGSize(width: 148 * mm, height: 210 * mm)
        case .b5: return CGSize(width: 176 * mm, height: 250 * mm)
        case .letter: return CGSize(width: 612, height: 792)
        case .legal: return CGSize(width: 612, height: 1008)
        case .wide: return CGSize(width: 960, height: 540)
        case .standard: return CGSize(width: 720, height: 540)
        case .custom: return nil
        }
    }
}

enum PDFCreationUnit: String, CaseIterable, Identifiable {
    case mm, cm, inch = "in", point = "pt"
    var id: String { rawValue }
    var points: Double {
        switch self {
        case .mm: return 72 / 25.4
        case .cm: return 72 / 2.54
        case .inch: return 72
        case .point: return 1
        }
    }
}

struct PDFCreationOptions: Codable, Equatable {
    static let settingsKey = "KongFolio.pdfCreation.options"
    static let presetsKey = "KongFolio.pdfCreation.presets"
    var width: Double = 210 * 72 / 25.4
    var height: Double = 297 * 72 / 25.4
    var pageCount = 1
    var pattern = PDFPaperPattern.blank
    var color = PDFCreationColor()
    var spacing: Double = 7 * 72 / 25.4
    var top: Double = 20 * 72 / 25.4
    var bottom: Double = 20 * 72 / 25.4
    var left: Double = 20 * 72 / 25.4
    var right: Double = 20 * 72 / 25.4
    var pageSize: CGSize { CGSize(width: width, height: height) }
    var valid: Bool {
        [width,height,spacing,top,bottom,left,right,color.red,color.green,color.blue].allSatisfy(\.isFinite)
        && (72...7200).contains(width) && (72...7200).contains(height) && (1...200).contains(pageCount)
        && (4...150).contains(spacing) && [top,bottom,left,right].allSatisfy { $0 >= 0 }
        && left + right < width && top + bottom < height
        && [color.red,color.green,color.blue].allSatisfy { (0...1).contains($0) }
    }
    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: settingsKey), let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return Self() }
        return value
    }
    func save(_ defaults: UserDefaults) {
        if valid, let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.settingsKey) }
    }
}

struct PDFCreationPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var options: PDFCreationOptions
}

enum PDFCreationService {
    static func blank(_ options: PDFCreationOptions) throws -> Data {
        guard options.valid else { throw FolioError(message: "请检查纸张尺寸、页数、边距和底纹间距。页数范围为 1–200。") }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: options.pageSize)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw FolioError(message: "无法创建 PDF 画布") }
        for _ in 0..<options.pageCount {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            try drawPaper(options, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func drawPaper(_ options: PDFCreationOptions, in context: CGContext) throws {
        let box = CGRect(origin: .zero, size: options.pageSize)
        context.setFillColor(options.color.nsColor.cgColor)
        context.fill(box)
        guard options.pattern != .blank else { return }
        let area = CGRect(x: options.left, y: options.bottom, width: options.width-options.left-options.right, height: options.height-options.top-options.bottom)
        let dark = options.color.red * 0.2126 + options.color.green * 0.7152 + options.color.blue * 0.0722 < 0.4
        context.setStrokeColor((dark ? NSColor.white : NSColor.darkGray).withAlphaComponent(0.22).cgColor)
        context.setFillColor((dark ? NSColor.white : NSColor.darkGray).withAlphaComponent(0.3).cgColor)
        context.setLineWidth(0.5)
        context.saveGState(); context.clip(to: area)
        let gap = options.spacing
        if options.pattern == .dotted {
            for x in stride(from: area.minX, through: area.maxX, by: gap) {
                try Task.checkCancellation()
                for y in stride(from: area.minY, through: area.maxY, by: gap) {
                    context.fillEllipse(in: CGRect(x: x-0.65, y: y-0.65, width: 1.3, height: 1.3))
                }
            }
        } else if options.pattern == .music {
            for start in stride(from: area.maxY-gap, through: area.minY+gap*4, by: -gap*8) {
                for line in 0..<5 {
                    let y = start-Double(line)*gap
                    context.move(to: CGPoint(x: area.minX, y: y)); context.addLine(to: CGPoint(x: area.maxX, y: y))
                }
            }
        } else {
            let writingBottom = options.pattern == .cornell ? area.minY + area.height * 0.18 : area.minY
            let writingLeft = options.pattern == .cornell ? area.minX + area.width * 0.27 : area.minX
            for y in stride(from: area.maxY-gap, through: writingBottom, by: -gap) {
                context.move(to: CGPoint(x: writingLeft, y: y)); context.addLine(to: CGPoint(x: area.maxX, y: y))
            }
            if options.pattern == .grid {
                for x in stride(from: area.minX, through: area.maxX, by: gap) {
                    context.move(to: CGPoint(x: x, y: area.minY)); context.addLine(to: CGPoint(x: x, y: area.maxY))
                }
            }
            if options.pattern == .cornell {
                context.move(to: CGPoint(x: writingLeft, y: writingBottom)); context.addLine(to: CGPoint(x: writingLeft, y: area.maxY))
                context.move(to: CGPoint(x: area.minX, y: writingBottom)); context.addLine(to: CGPoint(x: area.maxX, y: writingBottom))
            }
        }
        context.strokePath(); context.restoreGState()
    }

    static func combine(_ urls: [URL]) async throws -> Data {
        guard !urls.isEmpty else { throw FolioError(message: "请先添加文件") }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        try await CloudFilePreparation.prepare(urls) { _ in }
        let document = PDFDocument()
        for url in urls {
            try Task.checkCancellation()
            let bytes = try ImportServices.documentData(url)
            guard let source = PDFDocument(data: bytes), !source.isLocked, source.pageCount > 0 else { throw FolioError(message: "无法转换：\(url.lastPathComponent)") }
            for index in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: index)?.copy() as? PDFPage else { throw FolioError(message: "无法读取 \(url.lastPathComponent) 第 \(index+1) 页") }
                document.insert(page, at: document.pageCount)
            }
        }
        return try document.dataRepresentation().unwrap("文件转换失败")
    }

    /// Split a vector web PDF into paper pages while retaining its text layer.
    static func paginate(_ data: Data, options: PDFCreationOptions) throws -> Data {
        guard options.valid, let source = CGPDFDocument(CGDataProvider(data: data as CFData)!), let page = source.page(at: 1) else { throw FolioError(message: "网页 PDF 无法读取") }
        let bounds = page.getBoxRect(.mediaBox)
        let width = options.width-options.left-options.right
        let height = options.height-options.top-options.bottom
        let scale = width / bounds.width
        let count = Int(ceil(bounds.height*scale/height))
        guard (1...1000).contains(count) else { throw FolioError(message: "网页过长，请缩小网页范围后重试") }
        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: options.pageSize)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw FolioError(message: "无法创建分页 PDF") }
        var paper = options
        paper.pattern = .blank; paper.color = PDFCreationColor()
        for index in 0..<count {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            try drawPaper(paper, in: context)
            context.saveGState()
            context.clip(to: CGRect(x: options.left, y: options.bottom, width: width, height: height))
            context.translateBy(x: options.left, y: options.height-options.top-bounds.height*scale+Double(index)*height)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawPDFPage(page)
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }
}

extension WorkspaceStore {
    @discardableResult func adoptCreatedPDF(_ data: Data, title: String, emptyPaper: Bool = false) throws -> Workspace {
        guard let document = PDFDocument(data: data), document.pageCount > 0, !document.isLocked else { throw FolioError(message: "新建 PDF 失败") }
        let workspace = addWorkspace()
        workspace.document = document
        workspace.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名 PDF" : title
        workspace.isMakingPDF = true
        workspace.edited(reset: true)
        if emptyPaper { workspace.emptyCreationPDF = try? workspace.pdfData() }
        workspace.status = "已创建 PDF，可添加文字、图片和标注"
        return workspace
    }
}

extension Workspace {
    /// Protect external files and pages containing text, images or marks, while letting empty drafts close.
    var canDiscardEmptyCreation: Bool {
        guard sourceURL == nil, projectURL == nil, !saving, !busy, !drawingInProgress,
              placingSignature == nil, !hasPrivateReadingData,
              outlineEntries.isEmpty, count > 0 else { return false }
        let pages = (0..<count).compactMap { document.page(at: $0) }
        guard pages.count == count, pages.allSatisfy({ $0.annotations.isEmpty }) else { return false }
        if let emptyCreationPDF {
            if cachedPDF == emptyCreationPDF { return true }
            guard let paper = PDFDocument(data: emptyCreationPDF) else { return false }
            let paperStreams = Set((0..<paper.pageCount).compactMap { index in
                paper.page(at: index)?.pageRef
                    .flatMap(PDFCreationService.contentStreams)
                    .flatMap(PDFCreationService.paperTokens)
            })
            return pages.allSatisfy { page in
                PDFCreationService.readContentStreams(page).map {
                    guard let tokens = PDFCreationService.paperTokens($0) else { return false }
                    return tokens.isEmpty || paperStreams.contains(tokens)
                } ?? false
            }
        }
        // Older recovery files did not record the initial paper.
        guard title == "未命名 PDF", pages.count == 1 else { return false }
        return PDFCreationService.readContentStreams(pages[0]).map(PDFCreationService.emptyContents) ?? false
    }
}

extension PDFCreationService {
    static func readContentStreams(_ page: PDFPage) -> [Data]? {
        if let reference = page.pageRef { return contentStreams(reference) }
        guard let copy = page.copy() as? PDFPage else { return nil }
        let single = PDFDocument()
        single.insert(copy, at: 0)
        guard let data = single.dataRepresentation(), let snapshot = PDFDocument(data: data) else { return nil }
        return withExtendedLifetime(snapshot) { snapshot.page(at: 0)?.pageRef.flatMap(contentStreams) }
    }

    static func contentStreams(_ page: CGPDFPage) -> [Data]? {
        guard let dictionary = page.dictionary else { return nil }
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream {
            return decoded(stream).map { [$0] }
        }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array {
            var streams: [Data] = []
            for index in 0..<CGPDFArrayGetCount(array) {
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(array, index, &stream), let stream, let data = decoded(stream) else { return nil }
                streams.append(data)
            }
            return streams
        }
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, "Contents", &object) ? nil : []
    }

    private static func decoded(_ stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(stream, &format).map { $0 as Data }
    }

    static func emptyContents(_ streams: [Data]) -> Bool {
        paperTokens(streams)?.isEmpty == true
    }

    static func paperTokens(_ streams: [Data]) -> [String]? {
        var result: [String] = []
        for data in streams {
            guard let text = String(data: data, encoding: .ascii) else { return nil }
            // PDFKit can add graphics-state wrappers and reflow whitespace when it copies paper to a new page.
            result.append(contentsOf: text.split { $0.isWhitespace || $0.asciiValue == 0 }
                .filter { $0 != "q" && $0 != "Q" }.map(String.init))
        }
        // PDFKit can add a page-box clip during serialization and omit it when the page is copied.
        if result.count >= 7, Array(result[4..<7]) == ["re", "W", "n"],
           result.prefix(4).allSatisfy({ Double($0)?.isFinite == true }) {
            result.removeFirst(7)
        }
        return result
    }
}
