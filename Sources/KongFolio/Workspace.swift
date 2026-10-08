import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class Workspace: ObservableObject {
    @Published var sidebarTab = "页面"
    @Published var readingLayout = "连续"
    @Published var bookmarks: [PageBookmark] = []
    @Published var bookmarkName = ""
    @Published var outlineEntries: [OutlineEntry] = []
    @Published var searchResults: [SearchHit] = []
    @Published var searchMessage = ""
    @Published var annotationNotes: [AnnotationNote] = []
    @Published var showExport = false
    @Published var exportOptions = ExportOptions()
    @Published var exportEstimate: ExportEstimate?
    @Published var estimating = false
    @Published var showOCRReview = false
    @Published var reviewSelection = -1
    var ocrOriginals: [Int: Data] = [:]
    @Published var ocrRegions: [Int: [RecognizedLine]] = [:]
    var readingPoint: CGPoint?
    var readingScale: Double?
    var navigationToken = UUID()
    var searchTask: Task<[SearchHit], Error>?
    var estimateTask: Task<ExportEstimate, Error>?
    var cancelAuxiliary: (() -> Void)?
    private var cachedPDF: Data?
    let thumbnails = ThumbnailCache()
    @Published var document = PDFDocument()
    @Published var selection = 0
    @Published var selectedPages: Set<Int> = [0]
    @Published var rangeText = ""
    @Published var revision = UUID()
    @Published var title = "未命名文档"
    @Published var mode = "Document"
    @Published var tool = "选择"
    @Published var note = ""
    @Published var status = "所有处理均在本机完成"
    @Published var error: String?
    @Published var busy = false
    @Published var progress = 0.0
    @Published var taskLabel = ""
    @Published var dirty = false
    @Published var showTools = false
    @Published var adjustments = ImageAdjustments()
    @Published var preview: NSImage?
    @Published var showOriginal = false
    @Published var cropMode = false
    @Published var comparison: PDFDocument?
    @Published var recognizedText = ""
    @Published var search = ""
    @Published var recentFiles: [String] = []
    @Published var recoveryStatus = ""
    @Published var pendingImports: [URL] = []
    @Published var showImportOrder = false
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var annotationColor = Color.blue
    @Published var signatures: [SignatureTemplate] = []
    @Published var projectURL: URL?
    weak var pdfView: PDFView?
    var recipes: [Int: ImageRecipe] = [:]
    var imageDrafts: [Int: ImageAdjustments] = [:]
    private var history: [ProjectArchive] = []
    private var future: [ProjectArchive] = []
    private var imageBase: CGImage?
    private var importAsInsert = false
    private var autoTask: Task<Void, Never>?
    var activeJob: Task<JobResult, Error>?
    var lastJob: JobSpec?
    private var started = false
    private var discarded = false
    private let writer = RecoveryWriter()
    let storage: URL
    init(storage: URL? = nil) {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
    }
    var recoveryURL: URL { storage.appendingPathComponent("Recovery.kongfolio") }
    var count: Int { document.pageCount }
    var page: PDFPage? { document.page(at: selection) }
    var effectivePages: [Int] { let valid = selectedPages.filter { $0 >= 0 && $0 < count }.sorted(); return valid.isEmpty && count > 0 ? [selection] : valid }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var canRetry: Bool { lastJob != nil && !busy }
    var hasImageDraft: Bool { imageDrafts[selection] != nil }
    var originalPreview: NSImage? { imageBase.map { NSImage(cgImage: $0, size: .zero) } }
    var currentAnnotations: [PDFAnnotation] { page?.annotations.filter { $0.type != "Link" && $0.type != "Widget" } ?? [] }
    func report(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func pdfData() throws -> Data {
        if let cachedPDF { return cachedPDF }
        guard count > 0, let data = document.dataRepresentation() else { throw FolioError(message: "没有可保存的文档。") }
        cachedPDF = data; return data
    }
    func snapshot() throws -> ProjectArchive {
        let pdf = try pdfData()
        return ProjectArchive(reading: ReadingState(bookmarks: bookmarks, outline: outlineEntries, layout: readingLayout, point: readingPoint, scale: readingScale), ocrOriginals: ocrOriginals, ocrRegions: ocrRegions, pdf: pdf, title: title, selection: selection, selectedPages: Set(effectivePages), mode: mode, recipes: recipes, drafts: imageDrafts, dirty: dirty, projectPath: projectURL?.path)
    }
    func restore(_ archive: ProjectArchive, keepProjectURL: Bool = false) throws {
        try archive.validate()
        document = PDFDocument(data: archive.pdf)!; cachedPDF = archive.pdf
        bookmarks = archive.reading?.bookmarks ?? []; outlineEntries = archive.reading?.outline ?? ReadingServices.outline(document)
        readingLayout = archive.reading?.layout ?? "连续"; readingPoint = archive.reading?.point; readingScale = archive.reading?.scale
        ocrOriginals = archive.ocrOriginals ?? [:]; ocrRegions = archive.ocrRegions ?? [:]
        navigationToken = UUID(); thumbnails.clear(); searchTask?.cancel(); searchResults = []; annotationNotes = []
        title = archive.title; selection = archive.selection; selectedPages = archive.selectedPages; mode = archive.mode
        recipes = archive.recipes; imageDrafts = archive.drafts; dirty = archive.dirty
        if !keepProjectURL { projectURL = archive.projectPath.map { URL(fileURLWithPath: $0) } }
        revision = UUID(); selectedAnnotation = nil; resetImage()
        if mode == "Image", imageDrafts[selection] != nil { updatePreview(markDirty: false) }
    }
    func bootstrap() {
        guard !started else { return }; started = true
        recentFiles = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: storage.appendingPathComponent("Recent.json")))) ?? []
        signatures = (try? JSONDecoder().decode([SignatureTemplate].self, from: Data(contentsOf: storage.appendingPathComponent("Signatures.json")))) ?? []
        if FileManager.default.fileExists(atPath: recoveryURL.path), count == 0 {
            do { try restore(ProjectArchive.read(recoveryURL)); status = "已恢复上次工作，包括未导出的修改"; recoveryStatus = "已恢复" }
            catch { self.error = "恢复文件无法读取，原文件已保留：\(error.localizedDescription)" }
        }
    }
    func remember(_ urls: [URL]) {
        for url in urls.reversed() { recentFiles.removeAll { $0 == url.path }; recentFiles.insert(url.path, at: 0) }
        recentFiles = Array(recentFiles.prefix(12))
        report { try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true); try JSONEncoder().encode(recentFiles).write(to: storage.appendingPathComponent("Recent.json"), options: .atomic) }
    }
    func scheduleRecovery() {
        guard started, count > 0 else { return }
        autoTask?.cancel(); recoveryStatus = "等待自动保存"
        autoTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                let archive = try self.snapshot()
                self.writer.write(archive, to: self.recoveryURL) { [weak self] error in
                    Task { @MainActor in self?.recoveryStatus = error == nil ? "已自动保存恢复副本" : "自动保存失败"; if let error { self?.error = error.localizedDescription } }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult func flushRecovery() -> Bool {
        autoTask?.cancel()
        do { try writer.flush(count > 0 ? snapshot() : nil, to: recoveryURL); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func checkpoint() {
        if let archive = try? snapshot() { history.append(archive); while history.count > 1 && (history.count > 20 || history.reduce(0, { $0 + $1.pdf.count + $1.recipes.values.reduce(0, { $0 + $1.originalPDF.count }) }) > 192 * 1024 * 1024) { history.removeFirst() } }
        future.removeAll(); dirty = true
    }
    func edited(reset: Bool = false) {
        dirty = true; revision = UUID(); cachedPDF = nil; thumbnails.clear()
        searchTask?.cancel(); searchResults = []; searchMessage = ""; annotationNotes = []
        if sidebarTab == "摘录" { refreshNotes() }
        selection = max(0, min(selection, count - 1)); selectedPages = Set(effectivePages)
        if reset { selectedAnnotation = nil; resetImage() }
        scheduleRecovery()
    }
    func changed() { edited(reset: true) }
    func undo() {
        guard let archive = history.popLast() else { return }
        if let current = try? snapshot() { future.append(current) }
        report { try restore(archive, keepProjectURL: true); dirty = true; scheduleRecovery() }
    }
    func redo() {
        guard let archive = future.popLast() else { return }
        if let current = try? snapshot() { history.append(current) }
        report { try restore(archive, keepProjectURL: true); dirty = true; scheduleRecovery() }
    }
    @discardableResult func saveProject(asNew: Bool = false, background: Bool = true) -> Bool {
        guard count > 0 else { return false }
        let url: URL
        if let existing = projectURL, !asNew { url = existing }
        else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "com.kongfolio.project")]; panel.nameFieldStringValue = title + ".kongfolio"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }; url = chosen
        }
        do {
            var archive = try snapshot(); archive.projectPath = url.path; archive.dirty = false
            if background {
                busy = true; progress = 0; taskLabel = "保存项目…"
                let captured = archive
                Task {
                    defer { busy = false }
                    do { try await Task.detached { try captured.write(url) }.value; projectURL = url; dirty = false; remember([url]); scheduleRecovery(); status = "项目已保存" }
                    catch { self.error = error.localizedDescription }
                }
                return true
            }
            try archive.write(url); projectURL = url; dirty = false; remember([url]); scheduleRecovery(); status = "项目已保存"; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func confirmReplace() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "保存当前工作？"; alert.informativeText = "保存为 KongFolio 项目可保留页面、标注、原始图片和未应用的调整。"
        alert.addButton(withTitle: "保存项目"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject(background: false)
        case .alertThirdButtonReturn:
            autoTask?.cancel()
            do { try writer.flush(nil, to: recoveryURL) } catch { self.error = error.localizedDescription; return false }
            dirty = false; discarded = true; return true
        default: return false
        }
    }
    func prepareToClose() -> Bool {
        captureReadingPosition()
        guard !busy else { status = "请等待任务完成或点击取消任务"; return false }
        if dirty {
            guard confirmReplace() else { return false }
            // A discarded recovery file must not be recreated during termination.
            if discarded { return true }
        }
        return count == 0 ? true : flushRecovery()
    }
    func pickFiles() -> [URL] {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf, .jpeg, .png, .heic, .tiff, UTType(exportedAs: "com.kongfolio.project")]; panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    func open(insert: Bool = false) {
        guard !busy else { return }
        let urls = pickFiles(); guard !urls.isEmpty else { return }
        if urls.count > 1 { pendingImports = urls; importAsInsert = insert; showImportOrder = true }
        else { load(urls, insert: insert) }
    }
    func finishImport() { let urls = pendingImports; showImportOrder = false; load(urls, insert: importAsInsert); pendingImports = [] }
    func load(_ urls: [URL], insert: Bool = false, scanAfter: Bool = false, prepared: ImportPayload? = nil) {
        guard !urls.isEmpty, !busy else { return }
        if prepared == nil { startImport(urls, insert: insert, scanAfter: scanAfter); return }
        report {
            if urls.contains(where: { $0.pathExtension.lowercased() == "kongfolio" }) {
                guard urls.count == 1, !insert else { throw FolioError(message: "请单独打开 KongFolio 项目；合并时使用 PDF 或图片。") }
                guard case .project(let archive) = prepared else { throw FolioError(message: "项目读取失败") }
                guard confirmReplace() else { return }
                try restore(archive); discarded = false; projectURL = urls[0]; history.removeAll(); future.removeAll(); remember(urls); scheduleRecovery(); status = "项目已打开"; return
            }
            guard case .documents(let data) = prepared else { throw FolioError(message: "文档读取失败") }
            let loaded = try data.map { try PDFDocument(data: $0).unwrap("文档读取失败") }
            guard insert || confirmReplace() else { return }
            if insert {
                checkpoint()
                let offset = min(selection + 1, count)
                let added = loaded.reduce(0) { $0 + $1.pageCount }
                bookmarks = bookmarks.map { var b = $0; if b.page >= offset { b.page += added }; return b }
                outlineEntries = outlineEntries.map { var e = $0; if e.page >= offset { e.page += added }; return e }
                var start = offset
                for doc in loaded { outlineEntries += ReadingServices.outline(doc).map { var e = $0; e.page += start; return e }; start += doc.pageCount }
                ocrOriginals = Dictionary(uniqueKeysWithValues: ocrOriginals.map { ($0.key >= offset ? $0.key + added : $0.key, $0.value) })
                ocrRegions = Dictionary(uniqueKeysWithValues: ocrRegions.map { ($0.key >= offset ? $0.key + added : $0.key, $0.value) })
                recipes = Dictionary(uniqueKeysWithValues: recipes.map { ($0.key >= offset ? $0.key + added : $0.key, $0.value) })
                imageDrafts = Dictionary(uniqueKeysWithValues: imageDrafts.map { ($0.key >= offset ? $0.key + added : $0.key, $0.value) })
                var at = offset
                for doc in loaded { for i in 0..<doc.pageCount { if let page = doc.page(at: i)?.copy() as? PDFPage { document.insert(page, at: at); at += 1 } } }
                selection = offset; selectedPages = Set(offset..<at); ReadingServices.applyOutline(outlineEntries, to: document)
            } else {
                let combined = loaded.count == 1 ? loaded[0] : PDFDocument()
                if loaded.count > 1 {
                    var outlines: [OutlineEntry] = []
                    for doc in loaded { let offset = combined.pageCount; outlines += ReadingServices.outline(doc).map { var e = $0; e.page += offset; return e }; for i in 0..<doc.pageCount { if let page = doc.page(at: i)?.copy() as? PDFPage { combined.insert(page, at: combined.pageCount) } } }
                    ReadingServices.applyOutline(outlines, to: combined)
                }
                bookmarks = []; ocrOriginals = [:]; ocrRegions = [:]; outlineEntries = ReadingServices.outline(combined)
                document = combined; title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "合并文档"
                selection = 0; selectedPages = [0]; history.removeAll(); future.removeAll(); recipes = [:]; imageDrafts = [:]; projectURL = nil
                mode = urls.count == 1 && urls[0].pathExtension.lowercased() != "pdf" ? "Image" : "Document"
            }
            readingPoint = nil; readingScale = nil; navigationToken = UUID(); discarded = false; recognizedText = ""; changed(); if scanAfter { mode = "Image"; adjustments.scan = true; updatePreview() }; remember(urls); status = "已载入 \(count) 页"
        }
    }
    func selectPage(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard index >= 0, index < count else { return }
        if modifiers.contains(.shift) { selectedPages = Set(min(selection, index)...max(selection, index)) }
        else if modifiers.contains(.command) { if selectedPages.contains(index) && selectedPages.count > 1 { selectedPages.remove(index) } else { selectedPages.insert(index) } }
        else { selectedPages = [index] }
        readingPoint = nil; navigationToken = UUID(); selection = index; selectedAnnotation = nil; resetImage(); scheduleRecovery()
    }
    func selectRange() { report { readingPoint = nil; navigationToken = UUID(); selectedPages = Set(try PageRange.parse(rangeText, count: count)); selection = effectivePages.first ?? 0; resetImage(); scheduleRecovery() } }
    func rebuild(order: [Int], selected: Set<Int>) {
        let oldRecipes = recipes, oldDrafts = imageDrafts, oldOriginals = ocrOriginals, oldRegions = ocrRegions
        let oldBookmarks = bookmarks, oldOutline = outlineEntries
        bookmarks = []; outlineEntries = []; ocrOriginals = [:]; ocrRegions = [:]
        for (index, old) in order.enumerated() {
            bookmarks += oldBookmarks.filter { $0.page == old }.map { var b = $0; b.id = UUID(); b.page = index; return b }
            outlineEntries += oldOutline.filter { $0.page == old }.map { var e = $0; e.id = UUID(); e.page = index; return e }
            ocrOriginals[index] = oldOriginals[old]; ocrRegions[index] = oldRegions[old]
        }
        readingPoint = nil; navigationToken = UUID()
        document = DocumentServices.subset(document, indexes: order)
        ReadingServices.applyOutline(outlineEntries, to: document)
        recipes = [:]; imageDrafts = [:]
        for (index, old) in order.enumerated() { recipes[index] = oldRecipes[old]; imageDrafts[index] = oldDrafts[old] }
        selectedPages = selected; selection = selected.sorted().first ?? 0; changed(); status = "页面操作完成，共 \(count) 页"
    }
    func move(_ delta: Int) {
        let selected = Set(effectivePages)
        guard !selected.isEmpty, (delta < 0 ? selected.min()! > 0 : selected.max()! < count - 1) else { return }
        var order = Array(0..<count)
        for index in (delta < 0 ? effectivePages : effectivePages.reversed()) { order.swapAt(index, index + delta) }
        checkpoint(); rebuild(order: order, selected: Set(selected.map { $0 + delta }))
    }
    func movePages(before target: Int, dragged: Int) {
        guard (0...count).contains(target), (0..<count).contains(dragged) else { return }
        let moving = selectedPages.contains(dragged) ? effectivePages : [dragged]
        guard !moving.contains(target) else { return }
        var order = (0..<count).filter { !moving.contains($0) }
        let insertion = min(order.count, target - moving.filter { $0 < target }.count)
        order.insert(contentsOf: moving, at: max(0, insertion))
        guard order != Array(0..<count) else { return }
        checkpoint(); rebuild(order: order, selected: Set(insertion..<(insertion + moving.count)))
    }
    func duplicatePages() {
        guard count > 0 else { return }; let chosen = effectivePages; let at = (chosen.last ?? selection) + 1
        var order = Array(0..<count); order.insert(contentsOf: chosen, at: at)
        checkpoint(); rebuild(order: order, selected: Set(at..<(at + chosen.count)))
    }
    func remove() {
        let chosen = Set(effectivePages)
        guard chosen.count < count else { error = "文档至少保留一页。"; return }
        let next = min(chosen.min() ?? 0, count - chosen.count - 1)
        checkpoint(); rebuild(order: (0..<count).filter { !chosen.contains($0) }, selected: [next])
    }
    func rotate() {
        guard count > 0 else { return }; checkpoint()
        for i in effectivePages {
            if let data = ocrOriginals[i], let source = PDFDocument(data: data), let page = source.page(at: 0) { page.rotation = (page.rotation + 90) % 360; ocrOriginals[i] = source.dataRepresentation() }
            ocrRegions[i] = ocrRegions[i]?.map { line in RecognizedLine(text: line.text, box: CGRect(x: line.box.minY, y: 1 - line.box.maxX, width: line.box.height, height: line.box.width), confidence: line.confidence) }
            if let page = document.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
            if recipes[i] != nil { recipes[i]?.adjustments.rotation += 1 }
            if imageDrafts[i] != nil { imageDrafts[i]?.rotation += 1 } }
        changed()
    }
    func resetImage() {
        imageBase = nil; preview = nil; showOriginal = false; cropMode = false
        adjustments = imageDrafts[selection] ?? recipes[selection]?.adjustments ?? ImageAdjustments()
        if mode == "Image", imageDrafts[selection] != nil || recipes[selection] != nil { updatePreview(markDirty: false) }
    }
    func sourceImage() throws -> CGImage {
        if let imageBase { return imageBase }
        let result: CGImage
        if let recipe = recipes[selection], let source = PDFDocument(data: recipe.originalPDF), let page = source.page(at: 0) { result = try DocumentServices.render(page, maxDimension: 3000) }
        else if let page { result = try DocumentServices.render(page, maxDimension: 3000) }
        else { throw FolioError(message: "没有可处理的页面。") }
        imageBase = result; return result
    }
    func updatePreview(markDirty: Bool = true) {
        report {
            preview = NSImage(cgImage: try DocumentServices.adjusted(sourceImage(), adjustments), size: .zero)
            if markDirty { imageDrafts[selection] = adjustments; dirty = true; scheduleRecovery() }
        }
    }
    func setCrop(_ rect: CGRect) {
        // Crop gesture coordinates refer to the currently displayed, already-cropped image.
        let previous = adjustments.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let inset = min(0.4, max(0, adjustments.crop))
        let base = previous.insetBy(dx: previous.width * inset, dy: previous.height * inset)
        adjustments.crop = 0
        adjustments.cropRect = CGRect(x: base.minX + rect.minX * base.width, y: base.minY + rect.minY * base.height, width: rect.width * base.width, height: rect.height * base.height)
        cropMode = false; updatePreview()
    }
    func resetAdjustments() { adjustments = ImageAdjustments(); updatePreview() }
    func detectPaper() {
        guard !busy else { return }
        report {
            let image = try sourceImage(); busy = true; taskLabel = "识别纸张边缘"; progress = 0
            Task {
                do { let corners = try await Task.detached { try DocumentServices.detectPaper(image) }.value; adjustments.perspective = corners; adjustments.cropRect = nil; updatePreview(); status = "已校正纸张透视，请检查预览" }
                catch { self.error = error.localizedDescription }
                busy = false
            }
        }
    }
    func applyImage() {
        guard let image = preview, let original = page else { return }
        report {
            let sourceData = try recipes[selection]?.originalPDF ?? DocumentServices.subset(document, indexes: [selection]).dataRepresentation().unwrap("原图保存失败")
            let baseDoc = PDFDocument(data: sourceData)!
            let bounds = baseDoc.page(at: 0)!.bounds(for: .cropBox)
            let maxPoints = max(bounds.width, bounds.height)
            let source = try sourceImage()
            let pointsPerPixel = maxPoints / CGFloat(max(source.width, source.height))
            guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw FolioError(message: "无法读取裁剪预览") }
            image.size = CGSize(width: CGFloat(pixels.width) * pointsPerPixel, height: CGFloat(pixels.height) * pointsPerPixel)
            guard let newPage = PDFPage(image: image) else { return }
            if !original.annotations.isEmpty && recipes[selection] != nil {
                let alert = NSAlert(); alert.messageText = "重新应用原图调整将替换当前页面上的后续标注"; alert.informativeText = "原始图像会保留，操作可撤销。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "继续")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            checkpoint(); recipes[selection] = ImageRecipe(originalPDF: sourceData, adjustments: adjustments); imageDrafts[selection] = nil
            ocrOriginals[selection] = nil; ocrRegions[selection] = nil
            document.removePage(at: selection); document.insert(newPage, at: selection); ReadingServices.applyOutline(outlineEntries, to: document); changed(); status = "已应用；项目保留原始页面，可重新调整"
        }
    }
    func restoreOriginalPage() {
        guard let recipe = recipes[selection], let original = PDFDocument(data: recipe.originalPDF)?.page(at: 0) else { return }
        checkpoint(); ocrOriginals[selection] = nil; ocrRegions[selection] = nil; document.removePage(at: selection); document.insert(original, at: selection); recipes[selection] = nil; imageDrafts[selection] = nil; ReadingServices.applyOutline(outlineEntries, to: document); changed()
    }
    func saveURL(type: UTType, suffix: String, name: String? = nil) -> URL? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.nameFieldStringValue = (name ?? title) + "." + suffix
        return panel.runModal() == .OK ? panel.url : nil
    }
    func checkDraftsForExport() -> Bool {
        guard imageDrafts.isEmpty else { error = "有图片调整尚未应用。请先应用到页面，再导出；保存项目可以保留这些调整。"; return false }; return true
    }
    func exportPDF(currentOnly: Bool = false) { openExport(format: "PDF", scope: currentOnly ? "选中页面" : "全部页面") }
    func exportImage(_ type: UTType, suffix: String) { openExport(format: suffix.uppercased(), scope: "当前页面") }
    func exportText(markdown: Bool) {
        guard checkDraftsForExport() else { return }
        let text = (0..<count).map { index in (markdown ? "## 第 \(index + 1) 页\n\n" : "") + (document.page(at: index)?.string ?? "") }.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "未发现文本，请先运行 OCR。"; return }
        guard let url = saveURL(type: markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText, suffix: markdown ? "md" : "txt") else { return }
        report { try text.write(to: url, atomically: true, encoding: .utf8); status = "已导出文本" }
    }
    func find() { startSearch() }
    func highlight() {
        guard let selected = pdfView?.currentSelection else { error = "请先在 PDF 中选中文字。扫描页需先 OCR。"; return }
        checkpoint()
        for line in selected.selectionsByLine() { for page in line.pages { let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil); annotation.color = .systemYellow.withAlphaComponent(0.4); annotation.contents = note; annotation.setValue(line.string ?? "", forAnnotationKey: ReadingServices.quoteKey); page.addAnnotation(annotation) } }; edited()
    }
    func compare() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }; report { comparison = try DocumentServices.load(url) }
    }
    func quick(_ name: String) {
        showTools = false
        switch name {
        case "Merge PDFs": open(insert: count > 0)
        case "Compress PDF": compress()
        case "OCR PDF": ocr()
        case "Images → PDF": open()
        case "PDF → Images": exportBatch(split: false)
        case "Scan Document":
            let urls = pickFiles(); guard !urls.isEmpty else { return }
            load(urls, insert: count > 0, scanAfter: true)
        case "Sign PDF": mode = "Document"; tool = "签名"; status = "在页面上拖动手写签名；可将当前页墨迹保存到签名库"
        case "Compare PDFs": compare()
        default: break
        }
    }
}
extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let self else { throw FolioError(message: message) }; return self }
}
