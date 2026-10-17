import AppKit
import PDFKit

/// A named set of steps for a whole folder of scans: tidy the pages, cut the margins, recognise the text, and write a
/// searchable PDF and/or a Word file. (Not the per-page image recipe of the image mode.)
struct WorkRecipe: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Cut margins found from the content, one setting for odd and one for even pages.
    var autoCrop = false
    /// Scan enhancement and other image settings; nil leaves the pages alone.
    var cleanup: ImageAdjustments? = nil
    /// nil skips recognition (the files may already have text).
    var ocr: OCRSettings? = nil
    /// nil writes no Word file.
    var word: WordExportOptions? = nil
    /// Apply the correction list from the Word export window to the Word text.
    var useReplacementRules = true
    var writePDF = true

    var isEmpty: Bool { !autoCrop && cleanup == nil && ocr == nil && word == nil && !writePDF }

    var summary: String {
        var steps: [String] = []
        if cleanup != nil { steps.append("扫描增强") }
        if autoCrop { steps.append("自动裁边") }
        if let ocr { steps.append("OCR（\(ocr.vertical ? "竖排" : "横排")\(ocr.ignoresTextLayer ? "，忽略旧文字层" : "")）") }
        if writePDF { steps.append("输出 PDF") }
        if word != nil { steps.append("输出 Word") }
        return steps.isEmpty ? "没有任何步骤" : steps.joined(separator: " → ")
    }

    static let starters: [WorkRecipe] = [
        WorkRecipe(name: "繁体竖排古籍 → 可搜索 PDF + Word", autoCrop: true,
                   ocr: { var s = OCRSettings(); s.languages = ["zh-Hant", "en-US"]; s.vertical = true; s.ignoresTextLayer = true; return s }(),
                   word: WordExportOptions(), writePDF: true),
        WorkRecipe(name: "只裁边并整理（不做 OCR）", autoCrop: true, cleanup: { var a = ImageAdjustments(); a.scan = true; return a }(), writePDF: true),
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
}

enum BatchPipeline {
    /// Runs a recipe over one file. Everything happens in memory; `wordURL` is written before this returns.
    /// `progress` gets 0...1 for the file.
    static func process(_ data: Data, recipe: WorkRecipe, replacements: [ReplacementRule], wordURL: URL?, progress: (Double) -> Void = { _ in }) throws -> BatchOutput {
        guard let document = PDFDocument(data: data) else { throw FolioError(message: "无法读取这个 PDF。") }
        if document.isLocked, !document.unlock(withPassword: "") { throw FolioError(message: "文件需要密码才能打开。") }
        guard document.pageCount > 0 else { throw FolioError(message: "这个 PDF 没有页面。") }
        let count = document.pageCount
        var output = BatchOutput(pages: count)
        var regions: [Int: [RecognizedLine]] = [:]
        let steps = Double((recipe.cleanup != nil ? 1 : 0) + (recipe.autoCrop ? 1 : 0) + (recipe.ocr != nil ? 4 : 0) + (recipe.word != nil ? 2 : 0))
        var done = 0.0
        func step(_ weight: Double, _ fraction: Double) { progress(steps == 0 ? 1 : (done + weight * fraction) / steps) }

        if let adjustments = recipe.cleanup {
            for index in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let page = try document.page(at: index).unwrap("无法读取页面")
                    let replacement = try DocumentServices.cleanedPage(page, adjustments)
                    document.removePage(at: index)
                    document.insert(replacement, at: index)
                }
                step(1, Double(index + 1) / Double(count))
            }
            done += 1
        }
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
        if let options = recipe.word, let wordURL {
            var chosen = options
            chosen.replacements = recipe.useReplacementRules ? replacements : []
            _ = try WordExport.write(document, pages: Array(0..<count), outline: ReadingServices.outline(document), options: chosen, regions: regions, to: wordURL) { step(2, $0) }
            output.wordURL = wordURL
            done += 2
        }
        if recipe.writePDF { output.pdf = try document.dataRepresentation().unwrap("保存 PDF 失败") }
        progress(1)
        return output
    }
}

/// One file of a folder run.
struct BatchItem: Identifiable, Equatable {
    enum State: Equatable { case waiting, running, done(String), skipped(String), failed(String) }
    let id = UUID()
    var url: URL
    var state = State.waiting
}

/// Works through a folder of PDFs one file at a time and writes the results into another folder. Files whose
/// results already exist are skipped, so a stopped run picks up where it left off.
@MainActor final class BatchQueue: ObservableObject {
    @Published var items: [BatchItem] = []
    @Published var running = false
    @Published var fileProgress = 0.0
    @Published var summary = ""
    private var task: Task<Void, Never>?

    static func pdfFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return names.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The files a recipe would write for an input name.
    static func outputs(for input: URL, in folder: URL, recipe: WorkRecipe) -> (pdf: URL?, word: URL?) {
        let stem = input.deletingPathExtension().lastPathComponent
        return (recipe.writePDF ? folder.appendingPathComponent(stem + ".pdf") : nil, recipe.word != nil ? folder.appendingPathComponent(stem + ".docx") : nil)
    }

    func load(_ folder: URL) {
        items = Self.pdfFiles(in: folder).map { BatchItem(url: $0) }
        summary = items.isEmpty ? "这个文件夹里没有 PDF。" : "找到 \(items.count) 个 PDF。"
    }

    func start(recipe: WorkRecipe, output: URL, replacements: [ReplacementRule]) {
        guard !running, !items.isEmpty else { return }
        guard !recipe.isEmpty else { summary = "配方没有任何步骤。"; return }
        if let first = items.first?.url.deletingLastPathComponent().standardizedFileURL, first == output.standardizedFileURL {
            summary = "输出文件夹不能和原文件夹相同，以免覆盖原件。"
            return
        }
        running = true
        summary = ""
        for index in items.indices { items[index].state = .waiting }
        let queue = items
        task = Task {
            var done = 0, skipped = 0, failed = 0
            for (offset, item) in queue.enumerated() {
                if Task.isCancelled { break }
                let target = Self.outputs(for: item.url, in: output, recipe: recipe)
                let wanted = [target.pdf, target.word].compactMap { $0 }
                if wanted.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                    items[offset].state = .skipped("结果已存在")
                    skipped += 1
                    continue
                }
                items[offset].state = .running
                fileProgress = 0
                let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) { [self] in
                    do {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
                        let staging = target.word.map { $0.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString.prefix(8)).docx") }
                        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
                        let result = try BatchPipeline.process(data, recipe: recipe, replacements: replacements, wordURL: staging) { value in
                            Task { @MainActor in self.fileProgress = value }
                        }
                        try Task.checkCancellation()
                        if let pdf = result.pdf, let url = target.pdf { try Self.place(pdf, at: url) }
                        if let staging, let url = target.word, result.wordURL != nil { try Self.move(staging, to: url) }
                        return .success("\(result.pages) 页" + (result.recognized > 0 ? "，识别 \(result.recognized) 页" : ""))
                    } catch { return .failure(error) }
                }.value
                switch outcome {
                case .success(let note): items[offset].state = .done(note); done += 1
                case .failure(let error):
                    if error is CancellationError { items[offset].state = .waiting } else { items[offset].state = .failed(error.localizedDescription); failed += 1 }
                }
            }
            let stopped = Task.isCancelled
            running = false
            fileProgress = 0
            summary = (stopped ? "已停止：" : "完成：") + "处理 \(done) 个，跳过 \(skipped) 个，失败 \(failed) 个。" + (stopped ? "再次开始会跳过已经完成的文件。" : "")
        }
    }

    func cancel() { task?.cancel() }

    nonisolated static func place(_ data: Data, at url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString.prefix(8)).partial")
        try data.write(to: staging)
        try move(staging, to: url)
    }

    nonisolated static func move(_ staged: URL, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: url) }
    }
}
