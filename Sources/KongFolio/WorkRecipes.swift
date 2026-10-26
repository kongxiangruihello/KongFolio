import AppKit
import PDFKit

/// Page ranges as people write them: "1-20, 25, 40-" (page numbers start at 1; "40-" runs to the last page).
enum PageSpan {
    /// Zero-based page indexes in ascending order, nil when the text cannot be read. Empty text means every page.
    static func parse(_ text: String, pageCount: Int) -> [Int]? {
        let cleaned = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "－", with: "-").replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let parts = cleaned.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        guard !parts.isEmpty else { return Array(0..<pageCount) }
        var chosen = Set<Int>()
        for part in parts {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            switch ends.count {
            case 1:
                guard let page = Int(ends[0]), page >= 1 else { return nil }
                if page <= pageCount { chosen.insert(page - 1) }
            case 2:
                let low = ends[0].isEmpty ? 1 : Int(ends[0])
                let high = ends[1].isEmpty ? pageCount : Int(ends[1])
                guard let low, let high, low >= 1, high >= low else { return nil }
                if low <= pageCount { for page in low...min(high, pageCount) { chosen.insert(page - 1) } }
            default: return nil
            }
        }
        return chosen.sorted()
    }
}

/// A named set of steps for a whole folder of scans: tidy the pages, cut the margins, recognise the text, and write a
/// searchable PDF and/or a Word file. (Not the per-page image recipe of the image mode.)
struct WorkRecipe: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Cut margins found from the content, one setting for odd and one for even pages.
    var autoCrop = false
    var splitSpreads = false
    var splitFraction = 0.5
    var rightPageFirst = false
    var autoStraighten = false
    var compress: CompressLevel? = nil
    /// nil skips recognition (the files may already have text).
    var ocr: OCRSettings? = nil
    /// nil writes no Word file.
    var word: WordExportOptions? = nil
    /// Apply the correction list from the Word export window to the Word text.
    var useReplacementRules = true
    var writePDF = true
    /// Pages to keep, e.g. "3-400" to leave out the cover and the back matter; empty keeps every page.
    var pageRange = ""
    /// Also write one PDF per chapter (from the file's table of contents, or from headings found in the text).
    var splitChapters = false
    /// With no table of contents, look for headings such as 卷之一 / 第二章 in the recognised text.
    var detectHeadings = true
    /// 0 splits at volumes (卷, 篇…), 1 also at chapters.
    var chapterDepth = 0

    init(id: UUID = UUID(), name: String, autoCrop: Bool = false, ocr: OCRSettings? = nil, word: WordExportOptions? = nil,
         useReplacementRules: Bool = true, writePDF: Bool = true, pageRange: String = "", splitChapters: Bool = false, detectHeadings: Bool = true, chapterDepth: Int = 0) {
        self.id = id; self.name = name; self.autoCrop = autoCrop; self.ocr = ocr; self.word = word
        self.useReplacementRules = useReplacementRules; self.writePDF = writePDF
        self.pageRange = pageRange; self.splitChapters = splitChapters; self.detectHeadings = detectHeadings; self.chapterDepth = chapterDepth
    }

    enum CodingKeys: String, CodingKey {
        case id, name, autoCrop, ocr, word, useReplacementRules, writePDF, pageRange, splitChapters, detectHeadings, chapterDepth
        case splitSpreads, splitFraction, rightPageFirst, autoStraighten, compress
    }

    /// Recipes saved by 0.13 have none of the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        autoCrop = try c.decodeIfPresent(Bool.self, forKey: .autoCrop) ?? false
        ocr = try c.decodeIfPresent(OCRSettings.self, forKey: .ocr)
        word = try c.decodeIfPresent(WordExportOptions.self, forKey: .word)
        useReplacementRules = try c.decodeIfPresent(Bool.self, forKey: .useReplacementRules) ?? true
        writePDF = try c.decodeIfPresent(Bool.self, forKey: .writePDF) ?? true
        pageRange = try c.decodeIfPresent(String.self, forKey: .pageRange) ?? ""
        splitChapters = try c.decodeIfPresent(Bool.self, forKey: .splitChapters) ?? false
        detectHeadings = try c.decodeIfPresent(Bool.self, forKey: .detectHeadings) ?? true
        chapterDepth = try c.decodeIfPresent(Int.self, forKey: .chapterDepth) ?? 0
        splitSpreads = try c.decodeIfPresent(Bool.self, forKey: .splitSpreads) ?? false
        splitFraction = try c.decodeIfPresent(Double.self, forKey: .splitFraction) ?? 0.5
        rightPageFirst = try c.decodeIfPresent(Bool.self, forKey: .rightPageFirst) ?? false
        autoStraighten = try c.decodeIfPresent(Bool.self, forKey: .autoStraighten) ?? false
        compress = try c.decodeIfPresent(CompressLevel.self, forKey: .compress)
    }

    var isEmpty: Bool { !autoCrop && ocr == nil && word == nil && !writePDF && !splitChapters }

    var summary: String {
        var steps: [String] = []
        if !pageRange.trimmingCharacters(in: .whitespaces).isEmpty { steps.append("只取第 \(pageRange) 页") }
        if splitSpreads { steps.append("跨页切分") }
        if autoStraighten { steps.append("自动纠偏") }
        if autoCrop { steps.append("自动裁边") }
        if let ocr { steps.append("OCR（\(ocr.vertical ? "竖排" : "横排")\(ocr.ignoresTextLayer ? "，忽略旧文字层" : "")）") }
        if compress != nil { steps.append("压缩图片") }
        if writePDF { steps.append("输出 PDF") }
        if word != nil { steps.append("输出 Word") }
        if splitChapters { steps.append("按章节拆分") }
        return steps.isEmpty ? "没有任何步骤" : steps.joined(separator: " → ")
    }

    static let starters: [WorkRecipe] = [
        WorkRecipe(name: "繁体竖排古籍 → 可搜索 PDF + Word", autoCrop: true,
                   ocr: { var s = OCRSettings(); s.languages = ["zh-Hant", "en-US"]; s.vertical = true; s.ignoresTextLayer = true; return s }(),
                   word: WordExportOptions(), writePDF: true),
        WorkRecipe(name: "只裁边（不做 OCR）", autoCrop: true, writePDF: true),
        { var r = WorkRecipe(name: "双页扫描 → 整理、识别、压缩", autoCrop: true, ocr: OCRSettings()); r.splitSpreads = true; r.autoStraighten = true; r.compress = .standard; return r }(),
    ]
}

/// Recipes live in UserDefaults as JSON, so they survive restarts and need no document.
enum WorkRecipeStore {
    static let key = "KongFolio.workRecipes"

    static func load(_ defaults: UserDefaults = .standard) -> [WorkRecipe] {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([WorkRecipe].self, from: data) else { return WorkRecipe.starters }
        return list
    }

    static func save(_ recipes: [WorkRecipe], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(recipes) { defaults.set(data, forKey: key) }
    }
}

struct BatchOutput {
    var pdf: Data?
    var wordURL: URL?
    var pages = 0
    var recognized = 0
    /// One PDF per chapter, in book order, named for writing to a folder.
    var chapters: [(name: String, data: Data)] = []
}

enum BatchPipeline {
    /// Runs a recipe over one file. Everything happens in memory; `wordURL` is written before this returns.
    /// `progress` gets 0...1 for the file.
    static func process(_ data: Data, recipe: WorkRecipe, replacements: [ReplacementRule], wordURL: URL?, progress: (Double) -> Void = { _ in }) throws -> BatchOutput {
        guard var document = PDFDocument(data: data) else { throw FolioError(message: "无法读取这个 PDF。") }
        if document.isLocked, !document.unlock(withPassword: "") { throw FolioError(message: "文件需要密码才能打开。") }
        guard document.pageCount > 0 else { throw FolioError(message: "这个 PDF 没有页面。") }
        guard let keep = PageSpan.parse(recipe.pageRange, pageCount: document.pageCount) else { throw FolioError(message: "页码范围“\(recipe.pageRange)”无法理解，请写成 1-20, 25, 40- 这样。") }
        guard !keep.isEmpty else { throw FolioError(message: "页码范围“\(recipe.pageRange)”超出了这个文件的页数（\(document.pageCount) 页）。") }
        // The outline is read before the pages are picked, and follows them to their new places.
        var sourceOutline = ReadingServices.outline(document)
        if keep.count < document.pageCount {
            let picked = DocumentServices.subset(document, indexes: keep)
            document = picked
        }
        var newIndex: [Int: Int] = [:]
        for (offset, page) in keep.enumerated() { newIndex[page] = offset }
        if recipe.splitSpreads {
            guard recipe.splitFraction.isFinite, (0.2...0.8).contains(recipe.splitFraction) else { throw FolioError(message: "切分中缝必须在 20%–80% 之间。") }
            let divided = PDFDocument()
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let page = try document.page(at: index).unwrap("无法读取页面")
                for half in try ScanProcessing.halves(page, fraction: recipe.splitFraction, rightFirst: recipe.rightPageFirst) { divided.insert(half, at: divided.pageCount) }
            }
            for (old, index) in newIndex { newIndex[old] = index * 2 }
            document = divided
        }
        sourceOutline = sourceOutline.compactMap { entry -> OutlineEntry? in
            guard let moved = newIndex[entry.page] else { return nil }
            var copy = entry; copy.page = moved; return copy
        }
        ReadingServices.applyOutline(sourceOutline, to: document)
        let count = document.pageCount
        if recipe.autoStraighten {
            for index in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let page = try document.page(at: index).unwrap("无法读取页面")
                    let correction = try ScanProcessing.angle(page)
                    if abs(correction) >= 0.15 {
                        let replacement = try ScanProcessing.straightened(page, angle: correction)
                        document.removePage(at: index); document.insert(replacement, at: index)
                    }
                }
                progress(0.15 * Double(index + 1) / Double(count))
            }
            ReadingServices.applyOutline(sourceOutline, to: document)
        }
        var output = BatchOutput(pages: count)
        var regions: [Int: [RecognizedLine]] = [:]
        let steps = Double((recipe.autoCrop ? 1 : 0) + (recipe.ocr != nil ? 4 : 0) + (recipe.word != nil ? 2 : 0))
        var done = 0.0
        func step(_ weight: Double, _ fraction: Double) { progress(0.15 + 0.7 * (steps == 0 ? 1 : (done + weight * fraction) / steps)) }

        if recipe.autoCrop {
            var odd: [CropMargins] = [], even: [CropMargins] = []
            for index in 0..<count {
                try Task.checkCancellation()
                autoreleasepool {
                    guard let page = document.page(at: index), let bitmap = ContentBounds.render(page),
                          let found = ContentBounds.margins(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height) else { return }
                    if PageCrop.isOddPage(index) { odd.append(found) } else { even.append(found) }
                }
                step(1, Double(index + 1) / Double(count) * 0.9)
            }
            let oddCommon = ContentBounds.common(of: odd), evenCommon = ContentBounds.common(of: even)
            for index in 0..<count {
                guard let page = document.page(at: index) else { continue }
                let margins = PageCrop.isOddPage(index) ? (odd.isEmpty ? evenCommon : oddCommon) : (even.isEmpty ? oddCommon : evenCommon)
                page.setBounds(PageCrop.cropBox(mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation, margins: margins), for: .cropBox)
            }
            done += 1
        }
        if let settings = recipe.ocr {
            for index in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let page = try document.page(at: index).unwrap("无法读取页面")
                    guard settings.ignoresTextLayer || BackgroundJobs.textCharacterCount(page) < settings.minimumTextCharacters else { return }
                    let lines = try BackgroundJobs.recognize(page, settings: settings)
                    regions[index] = lines
                    output.recognized += 1
                    if !lines.isEmpty {
                        let replacement = try DocumentServices.searchablePage(page, lines: lines)
                        document.removePage(at: index)
                        document.insert(replacement, at: index)
                    }
                }
                step(4, Double(index + 1) / Double(count))
            }
            done += 4
        }
        ReadingServices.applyOutline(sourceOutline, to: document)
        if let level = recipe.compress {
            let original = try document.dataRepresentation().unwrap("无法准备压缩数据")
            let compressed = try PDFCompressor.compress(document, level: level, original: original.count, keepMarked: true) { progress(0.85 + 0.1 * $0) }
            if compressed.report.smaller {
                document = try PDFDocument(data: compressed.data).unwrap("压缩结果无法读取")
                ReadingServices.applyOutline(sourceOutline, to: document)
            }
        }
        if let options = recipe.word, let wordURL {
            var chosen = options
            chosen.replacements = recipe.useReplacementRules ? replacements : []
            _ = try WordExport.write(document, pages: Array(0..<count), outline: ReadingServices.outline(document), options: chosen, regions: regions, to: wordURL) { step(2, $0) }
            output.wordURL = wordURL
            done += 2
        }
        if recipe.splitChapters {
            var entries = sourceOutline
            if entries.isEmpty, recipe.detectHeadings {
                let pages = (0..<count).map { (page: $0, lines: openingLines(of: $0, document: document, regions: regions)) }
                entries = OutlineDetect.merged([], adding: OutlineDetect.candidates(pages: pages))
            }
            let parts = ChapterSplit.parts(entries: entries, pageCount: count, depth: recipe.chapterDepth)
            guard !parts.isEmpty else { throw FolioError(message: "未找到可拆分的章节目录或标题。") }
            for (offset, part) in parts.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    let data = try DocumentServices.subset(document, indexes: Array(part.pages)).dataRepresentation().unwrap("拆分失败")
                    output.chapters.append((ChapterSplit.fileName(index: offset + 1, total: parts.count, title: part.title), data))
                }
            }
        }
        if recipe.writePDF { output.pdf = try document.dataRepresentation().unwrap("保存 PDF 失败") }
        progress(1)
        return output
    }
}

extension BatchPipeline {
    /// The first lines of a page in reading order: the right-most columns of a recognised vertical page, else its text layer.
    static func openingLines(of index: Int, document: PDFDocument, regions: [Int: [RecognizedLine]], limit: Int = 4) -> [String] {
        if let columns = OrderedText.verticalColumns(regions[index] ?? []) { return Array(columns.prefix(limit)) }
        let text = ReadingServices.repairIdeographs(document.page(at: index)?.string ?? "")
        return Array(text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(limit))
    }
}

