import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class Workspace: ObservableObject {
    // MARK: Reading
    @Published var sidebarTab = SidebarTab.pages
    @Published var readingLayout = ReadingLayout.continuous
    @Published var bookmarks: [PageBookmark] = []
    @Published var bookmarkName = ""
    @Published var outlineEntries: [OutlineEntry] = []
    @Published var searchResults: [SearchHit] = []
    @Published var searchMessage = ""
    @Published var annotationNotes: [AnnotationNote] = []
    @Published var bibliography = Bibliography()
    @Published var markupStyle = MarkupStyle.highlight
    @Published var markupColor = MarkupColor.yellow
    var readingPoint: CGPoint?
    var readingScale: Double?
    var navigationToken = UUID()
    var searchTask: Task<[SearchHit], Error>?

    // MARK: Export and OCR
    @Published var showExport = false
    @Published var exportOptions = ExportOptions()
    @Published var exportEstimate: ExportEstimate?
    @Published var estimating = false
    @Published var showOCRReview = false
    @Published var reviewSelection = -1
    @Published var ocrSettings = OCRSettings.load() { didSet { if ocrSettings != oldValue { ocrSettings.save() } } }
    var estimateTask: Task<ExportEstimate, Error>?
    var cancelAuxiliary: (() -> Void)?

    // MARK: Document
    @Published var document = PDFDocument()
    /// Per-page state aligned with `document`; see `PageMeta`.
    @Published var pageMeta: [PageMeta] = []
    @Published var selection = 0
    @Published var selectedPages: Set<Int> = [0]
    @Published var rangeText = ""
    @Published var revision = UUID()
    @Published var title = "未命名文档"
    @Published var mode = WorkspaceMode.document
    @Published var tool = AnnotationTool.select
    @Published var note = ""
    @Published var status = "所有处理均在本机完成"
    @Published var error: String?
    @Published var busy = false { didSet { if oldValue && !busy { openDeferredFiles() } } }
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

    // MARK: Internal state
    let thumbnails = ThumbnailCache()
    /// Changes when page order or page content is replaced; thumbnails keyed on it are rebuilt.
    var layoutRevision = UUID()
    /// Bumped per page for annotation edits so only that page's thumbnail re-renders.
    var pageVersions: [Int: Int] = [:]
    var history: [UndoEntry] = []
    var future: [UndoEntry] = []
    var activeJob: Task<JobResult, Error>?
    var lastJob: JobSpec?
    /// How long the last full PDF serialization took; autosave backs off on large documents.
    var lastSerializationSeconds = 0.0
    var previewIsProxy = false
    /// Tests and scripts replace this to answer confirmation dialogs.
    static var confirmationHandler: ((_ title: String, _ detail: String) -> Bool)?
    private var cachedPDF: Data?
    private var imageBase: CGImage?
    private var proxyBase: CGImage?
    private var displayCache: (key: String, image: NSImage)?
    private var importAsInsert = false
    private var deferredOpen: (urls: [URL], insert: Bool)?
    private var autoTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var started = false
    private var discarded = false
    private let writer = RecoveryWriter.shared
    let storage: URL
    let id = UUID()
    /// Each tab keeps its own recovery copy. The first tab uses the empty slot, which is the file name earlier versions used.
    let slot: String
    weak var store: WorkspaceStore?

    init(storage: URL? = nil, slot: String = "") {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
        self.slot = slot
    }

    var recoveryURL: URL { storage.appendingPathComponent(slot.isEmpty ? "Recovery.kfrecovery" : "Recovery-\(slot).kfrecovery", isDirectory: true) }
    /// 0.2/0.3 kept the recovery copy as one JSON file (first tab only).
    var legacyRecoveryURL: URL { storage.appendingPathComponent(slot.isEmpty ? "Recovery.kongfolio" : "Recovery-\(slot).legacy-unused") }
    var count: Int { document.pageCount }
    var page: PDFPage? { document.page(at: selection) }
    var effectivePages: [Int] {
        let valid = selectedPages.filter { $0 >= 0 && $0 < count }.sorted()
        return valid.isEmpty && count > 0 ? [selection] : valid
    }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var canRetry: Bool { lastJob != nil && !busy }
    var hasImageDraft: Bool { meta(selection).draft != nil }
    var hasPendingDrafts: Bool { pageMeta.contains { $0.draft != nil } }
    var originalPreview: NSImage? { imageBase.map { NSImage(cgImage: $0, size: .zero) } }
    var currentAnnotations: [PDFAnnotation] { page.map(Workspace.visibleAnnotations) ?? [] }

    nonisolated static func visibleAnnotations(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { !["Link", "Widget", "Popup"].contains($0.type ?? "") }
    }

    func report(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }

    func confirm(_ title: String, _ detail: String, action: String) -> Bool {
        if let handler = Workspace.confirmationHandler { return handler(title, detail) }
        // Without a running application (unit tests, scripts) there is nobody to ask.
        guard NSApp != nil else { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: Per-page metadata

    func alignMeta() {
        if pageMeta.count < count { pageMeta += Array(repeating: PageMeta(), count: count - pageMeta.count) }
        else if pageMeta.count > count { pageMeta.removeLast(pageMeta.count - count) }
    }

    func meta(_ index: Int) -> PageMeta { pageMeta.indices.contains(index) ? pageMeta[index] : PageMeta() }

    func updateMeta(_ index: Int, _ change: (inout PageMeta) -> Void) {
        alignMeta()
        guard pageMeta.indices.contains(index) else { return }
        change(&pageMeta[index])
    }

    var recipes: [Int: ImageRecipe] {
        get { metaDictionary(\.recipe) }
        set { setMetaDictionary(\.recipe, newValue) }
    }
    var imageDrafts: [Int: ImageAdjustments] {
        get { metaDictionary(\.draft) }
        set { setMetaDictionary(\.draft, newValue) }
    }
    var ocrOriginals: [Int: Data] {
        get { metaDictionary(\.ocrOriginal) }
        set { setMetaDictionary(\.ocrOriginal, newValue) }
    }
    var ocrRegions: [Int: [RecognizedLine]] {
        get { metaDictionary(\.ocrRegions) }
        set { setMetaDictionary(\.ocrRegions, newValue) }
    }

    private func metaDictionary<T>(_ key: KeyPath<PageMeta, T?>) -> [Int: T] {
        var result: [Int: T] = [:]
        for (index, meta) in pageMeta.enumerated() { if let value = meta[keyPath: key] { result[index] = value } }
        return result
    }

    private func setMetaDictionary<T>(_ key: WritableKeyPath<PageMeta, T?>, _ values: [Int: T]) {
        let needed = max(count, (values.keys.max() ?? -1) + 1)
        if pageMeta.count < needed { pageMeta += Array(repeating: PageMeta(), count: needed - pageMeta.count) }
        for index in pageMeta.indices { pageMeta[index][keyPath: key] = values[index] }
    }

    // MARK: Snapshots and recovery

    func pdfData() throws -> Data {
        if let cachedPDF { return cachedPDF }
        let started = Date()
        guard count > 0, let data = document.dataRepresentation() else { throw FolioError(message: "没有可保存的文档。") }
        lastSerializationSeconds = Date().timeIntervalSince(started)
        cachedPDF = data
        return data
    }

    /// Autosave waits longer when serializing the document is slow, so editing a large book stays responsive.
    var recoveryDelay: Double { min(15, max(0.7, lastSerializationSeconds * 6)) }

    func snapshot() throws -> ProjectArchive {
        let pdf = try pdfData()
        alignMeta()
        let reading = ReadingState(bookmarks: bookmarks, outline: outlineEntries, layout: readingLayout, point: readingPoint, scale: readingScale, bibliography: bibliography.isEmpty ? nil : bibliography)
        return ProjectArchive(reading: reading, ocrOriginals: ocrOriginals, ocrRegions: ocrRegions, pdf: pdf, title: title, selection: selection, selectedPages: Set(effectivePages), mode: mode, recipes: recipes, drafts: imageDrafts, dirty: dirty, projectPath: projectURL?.path)
    }

    func restore(_ archive: ProjectArchive, keepProjectURL: Bool = false) throws {
        try archive.validate()
        document = try PDFDocument(data: archive.pdf).unwrap("项目中的 PDF 无法读取")
        cachedPDF = archive.pdf
        bookmarks = archive.reading?.bookmarks ?? []
        outlineEntries = archive.reading?.outline ?? ReadingServices.outline(document)
        readingLayout = archive.reading?.layout ?? .continuous
        readingPoint = archive.reading?.point
        readingScale = archive.reading?.scale
        bibliography = archive.reading?.bibliography ?? Bibliography()
        pageMeta = (0..<document.pageCount).map { index in
            PageMeta(recipe: archive.recipes[index], draft: archive.drafts[index], ocrOriginal: archive.ocrOriginals?[index], ocrRegions: archive.ocrRegions?[index])
        }
        navigationToken = UUID()
        layoutRevision = UUID()
        pageVersions = [:]
        thumbnails.clear()
        searchTask?.cancel()
        searchResults = []
        annotationNotes = []
        title = archive.title
        selection = archive.selection
        selectedPages = archive.selectedPages
        mode = archive.mode
        dirty = archive.dirty
        if !keepProjectURL { projectURL = archive.projectPath.map { URL(fileURLWithPath: $0) } }
        revision = UUID()
        selectedAnnotation = nil
        resetImage()
        if mode == .image, meta(selection).draft != nil { updatePreview(markDirty: false) }
    }

    func bootstrap() {
        guard !started else { return }
        started = true
        recentFiles = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: storage.appendingPathComponent("Recent.json")))) ?? []
        signatures = (try? JSONDecoder().decode([SignatureTemplate].self, from: Data(contentsOf: storage.appendingPathComponent("Signatures.json")))) ?? []
        let candidate = [recoveryURL, legacyRecoveryURL].first { FileManager.default.fileExists(atPath: $0.path) }
        if let candidate, count == 0 {
            do {
                try restore(ProjectArchive.read(candidate))
                status = "已恢复上次工作，包括未导出的修改"
                recoveryStatus = "已恢复"
            } catch {
                self.error = "恢复副本无法读取，已保留在“\(storage.path)”中：\(error.localizedDescription)"
            }
        }
    }

    func remember(_ urls: [URL]) {
        // Other tabs may have added files since this tab loaded the list; start from what is on disk.
        if let stored = try? JSONDecoder().decode([String].self, from: Data(contentsOf: storage.appendingPathComponent("Recent.json"))) {
            recentFiles = stored
        }
        for url in urls.reversed() {
            recentFiles.removeAll { $0 == url.path }
            recentFiles.insert(url.path, at: 0)
        }
        recentFiles = Array(recentFiles.prefix(12))
        report {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(recentFiles).write(to: storage.appendingPathComponent("Recent.json"), options: .atomic)
        }
    }

    func scheduleRecovery() {
        guard started, count > 0 else { return }
        autoTask?.cancel()
        guard dirty else {
            // Nothing to protect: the opened file or saved project is this very document. Copying it into the
            // recovery folder only cost disk time (a hash and a full write per opened PDF), and an older copy must
            // not be restored over what is on disk. Quitting still writes a copy so the session comes back.
            writer.discard(recoveryURL)
            recoveryStatus = ""
            return
        }
        recoveryStatus = "等待自动保存"
        let delay = recoveryDelay
        autoTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                let archive = try self.snapshot()
                let legacy = self.legacyRecoveryURL
                self.writer.write(archive, to: self.recoveryURL) { [weak self] error in
                    if error == nil { try? FileManager.default.removeItem(at: legacy) }
                    Task { @MainActor in
                        self?.recoveryStatus = error == nil ? "已自动保存恢复副本" : "自动保存失败"
                        if let error { self?.error = error.localizedDescription }
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @discardableResult func flushRecovery() -> Bool {
        autoTask?.cancel()
        do {
            try writer.flush(count > 0 ? snapshot() : nil, to: recoveryURL)
            try? FileManager.default.removeItem(at: legacyRecoveryURL)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Records a full snapshot for undo. Annotation edits use the cheaper entries in UndoHistory.swift.
    func checkpoint() {
        do { pushUndo(.snapshot(try snapshot())) }
        catch {
            // The chain of undo steps is broken from here on; keeping older steps would skip this edit.
            history.removeAll(); future.removeAll(); dirty = true
            self.error = "无法记录撤销步骤，此操作之前的撤销历史已清除，此操作不能撤销：\(error.localizedDescription)"
        }
    }

    /// Call after any change. `pdfChanged: false` for metadata such as bookmarks;
    /// `pages` limits thumbnail refresh to pages whose annotations changed.
    func edited(reset: Bool = false, pdfChanged: Bool = true, pages: Set<Int>? = nil) {
        dirty = true
        revision = UUID()
        if pdfChanged {
            cachedPDF = nil
            if let pages {
                for page in pages { pageVersions[page, default: 0] += 1 }
            } else {
                layoutRevision = UUID()
                pageVersions = [:]
                thumbnails.clear()
            }
            searchTask?.cancel()
            searchResults = []
            searchMessage = ""
            annotationNotes = []
            if sidebarTab == .notes { refreshNotes() }
        }
        alignMeta()
        selection = max(0, min(selection, count - 1))
        selectedPages = Set(effectivePages)
        if reset {
            selectedAnnotation = nil
            resetImage()
        }
        scheduleRecovery()
    }

    func changed() { edited(reset: true) }

    func thumbnailKey(_ index: Int) -> String { "\(layoutRevision)-\(index)-\(pageVersions[index] ?? 0)" }

    /// Cached page rendering for the image canvas and OCR review, so view updates don't re-render the page.
    func pageDisplayImage(maxDimension: CGFloat) -> NSImage? {
        guard let page else { return nil }
        let key = "\(thumbnailKey(selection))-\(Int(maxDimension))"
        if let displayCache, displayCache.key == key { return displayCache.image }
        let image = page.thumbnail(of: CGSize(width: maxDimension, height: maxDimension), for: .cropBox)
        displayCache = (key, image)
        return image
    }

    // MARK: Saving

    /// The previous version of a project is kept here when a save overwrites it (one version per project).
    var backupFolder: URL { storage.appendingPathComponent("Backups", isDirectory: true) }

    nonisolated static func savedStatus(_ backupError: Error?) -> String {
        backupError.map { "项目已保存，但未能备份上一版：\($0.localizedDescription)" } ?? "项目已保存"
    }

    @discardableResult func saveProject(asNew: Bool = false, background: Bool = true) -> Bool {
        guard count > 0 else { return false }
        let url: URL
        if let existing = projectURL, !asNew {
            url = existing
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(exportedAs: "com.kongfolio.project")]
            panel.nameFieldStringValue = title + ".kongfolio"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
        }
        do {
            var archive = try snapshot()
            archive.projectPath = url.path
            archive.dirty = false
            if background {
                busy = true
                progress = 0
                taskLabel = "保存项目…"
                let captured = archive
                let backups = backupFolder
                Task {
                    defer { busy = false }
                    do {
                        let backupError = try await Task.detached { () -> Error? in
                            let failure = ProjectBackup.preserve(url, in: backups)
                            try captured.write(url)
                            return failure
                        }.value
                        projectURL = url
                        dirty = false
                        remember([url])
                        scheduleRecovery()
                        status = Workspace.savedStatus(backupError)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                return true
            }
            let backupError = ProjectBackup.preserve(url, in: backupFolder)
            try archive.write(url)
            projectURL = url
            dirty = false
            remember([url])
            scheduleRecovery()
            status = Workspace.savedStatus(backupError)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func confirmReplace() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存当前工作？"
        alert.informativeText = "保存为 KongFolio 项目可保留页面、标注、原始图片和未应用的调整。"
        alert.addButton(withTitle: "保存项目")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject(background: false)
        case .alertThirdButtonReturn:
            autoTask?.cancel()
            do {
                try writer.flush(nil, to: recoveryURL)
                try? FileManager.default.removeItem(at: legacyRecoveryURL)
            } catch {
                self.error = error.localizedDescription
                return false
            }
            dirty = false
            discarded = true
            return true
        default:
            return false
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

    /// Closes this tab (or, when it is the only one, returns it to the start screen).
    func closeTab() {
        if let store { store.close(id) } else { closeDocument() }
    }

    /// Closes the current document or image and returns to the start screen. Unsaved work is confirmed first.
    /// The recovery copy is removed too, otherwise the closed document would be restored on the next launch.
    @discardableResult func closeDocument() -> Bool {
        guard count > 0 else { return false }
        guard !busy else { status = "请等待任务完成或点击取消任务"; return false }
        if dirty { guard confirmReplace() else { return false } }
        autoTask?.cancel()
        do {
            try writer.flush(nil, to: recoveryURL)
            try? FileManager.default.removeItem(at: legacyRecoveryURL)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        let closed = title
        searchTask?.cancel(); previewTask?.cancel(); estimateTask?.cancel()
        document = PDFDocument(); cachedPDF = nil
        pageMeta = []; selection = 0; selectedPages = [0]; rangeText = ""
        title = "未命名文档"; mode = .document; tool = .select; note = ""
        bookmarks = []; bookmarkName = ""; outlineEntries = []; bibliography = Bibliography()
        search = ""; searchResults = []; searchMessage = ""; annotationNotes = []
        readingPoint = nil; readingScale = nil
        selectedAnnotation = nil; comparison = nil; recognizedText = ""
        showOCRReview = false; reviewSelection = -1; exportEstimate = nil
        history.removeAll(); future.removeAll(); lastJob = nil
        projectURL = nil; dirty = false; discarded = false
        thumbnails.clear(); pageVersions = [:]
        layoutRevision = UUID(); navigationToken = UUID(); revision = UUID()
        resetImage()
        recoveryStatus = ""
        status = "已关闭“\(closed)”"
        return true
    }

    // MARK: Opening

    func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        var types: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff, .plainText, UTType(exportedAs: "com.kongfolio.project")]
        types += TextImport.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    func open(insert: Bool = false) {
        guard !busy else { return }
        let urls = pickFiles()
        guard !urls.isEmpty else { return }
        openSelected(urls, insert: insert)
    }

    func openSelected(_ urls: [URL], insert: Bool) {
        if urls.count > 1 {
            pendingImports = urls
            importAsInsert = insert
            showImportOrder = true
        } else {
            load(urls, insert: insert)
        }
    }

    /// Files dropped on the window: open them, or insert after the current page when a document is open.
    func openDropped(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL && (["pdf", "jpg", "jpeg", "png", "heic", "tif", "tiff", "kongfolio"].contains($0.pathExtension.lowercased()) || TextImport.handles($0)) }
        guard !files.isEmpty else { error = "只能拖入 PDF、图片、Markdown、TXT 或 KongFolio 项目。"; return }
        let isProject = files.contains { $0.pathExtension.lowercased() == "kongfolio" }
        var insert = false
        if count > 0, !isProject, NSApp != nil {
            let alert = NSAlert()
            alert.messageText = "如何处理拖入的 \(files.count) 个文件？"
            alert.addButton(withTitle: "插入到当前页之后")
            alert.addButton(withTitle: "打开为新文档")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: insert = true
            case .alertSecondButtonReturn: insert = false
            default: return
            }
        }
        openSelected(files, insert: insert)
    }

    private func openDeferredFiles() {
        guard let deferred = deferredOpen else { return }
        deferredOpen = nil
        DispatchQueue.main.async { [weak self] in self?.load(deferred.urls, insert: deferred.insert) }
    }

    func finishImport() {
        let urls = pendingImports
        showImportOrder = false
        load(urls, insert: importAsInsert)
        pendingImports = []
    }

    func load(_ urls: [URL], insert: Bool = false, scanAfter: Bool = false, prepared: ImportPayload? = nil) {
        guard !urls.isEmpty else { return }
        // A document that is already open stays open: new files go to a new tab. Inserting pages and the
        // prepared (already read) payload of a tab's own import are not routed.
        if !insert, prepared == nil, count > 0, let store {
            store.openInNewTab(urls, scanAfter: scanAfter)
            return
        }
        if busy {
            // Opening from Finder while a task runs used to be dropped silently; queue it instead.
            deferredOpen = (urls, insert)
            status = "当前任务完成后将打开：\(urls.map(\.lastPathComponent).joined(separator: "、"))"
            return
        }
        if prepared == nil { startImport(urls, insert: insert, scanAfter: scanAfter); return }
        report {
            if urls.contains(where: { $0.pathExtension.lowercased() == "kongfolio" }) {
                guard urls.count == 1, !insert else { throw FolioError(message: "请单独打开 KongFolio 项目；合并时使用 PDF 或图片。") }
                guard case .project(let archive) = prepared else { throw FolioError(message: "项目读取失败") }
                guard confirmReplace() else { return }
                try restore(archive)
                discarded = false
                projectURL = urls[0]
                history.removeAll()
                future.removeAll()
                remember(urls)
                scheduleRecovery()
                status = "项目已打开"
                return
            }
            guard case .documents(let data) = prepared else { throw FolioError(message: "文档读取失败") }
            var openedBytes: Data?
            let loaded = try data.map { try PDFDocument(data: $0).unwrap("文档读取失败") }
            guard insert || confirmReplace() else { return }
            if insert {
                checkpoint()
                alignMeta()
                let offset = min(selection + 1, count)
                let added = loaded.reduce(0) { $0 + $1.pageCount }
                bookmarks = bookmarks.map { var b = $0; if b.page >= offset { b.page += added }; return b }
                outlineEntries = outlineEntries.map { var e = $0; if e.page >= offset { e.page += added }; return e }
                var start = offset
                for doc in loaded {
                    outlineEntries += ReadingServices.outline(doc).map { var e = $0; e.page += start; return e }
                    start += doc.pageCount
                }
                pageMeta.insert(contentsOf: Array(repeating: PageMeta(), count: added), at: offset)
                var at = offset
                for doc in loaded {
                    for i in 0..<doc.pageCount {
                        if let page = doc.page(at: i)?.copy() as? PDFPage { document.insert(page, at: at); at += 1 }
                    }
                }
                selection = offset
                selectedPages = Set(offset..<at)
                ReadingServices.applyOutline(outlineEntries, to: document)
            } else {
                let combined = loaded.count == 1 ? loaded[0] : PDFDocument()
                if loaded.count > 1 {
                    var outlines: [OutlineEntry] = []
                    for doc in loaded {
                        let offset = combined.pageCount
                        outlines += ReadingServices.outline(doc).map { var e = $0; e.page += offset; return e }
                        for i in 0..<doc.pageCount {
                            if let page = doc.page(at: i)?.copy() as? PDFPage { combined.insert(page, at: combined.pageCount) }
                        }
                    }
                    ReadingServices.applyOutline(outlines, to: combined)
                }
                bookmarks = []
                outlineEntries = ReadingServices.outline(combined)
                bibliography = ReadingServices.bibliography(from: combined)
                document = combined
                pageMeta = Array(repeating: PageMeta(), count: combined.pageCount)
                title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "合并文档"
                selection = 0
                selectedPages = [0]
                history.removeAll()
                future.removeAll()
                projectURL = nil
                mode = urls.count == 1 && urls[0].pathExtension.lowercased() != "pdf" && !TextImport.handles(urls[0]) ? .image : .document
                if loaded.count == 1 { openedBytes = data.first }
            }
            readingPoint = nil
            readingScale = nil
            navigationToken = UUID()
            discarded = false
            recognizedText = ""
            changed()
            // The opened bytes are the document. Without this, the first autosave (and the first search)
            // serialized the whole file on the main thread. `changed()` clears the cache, so set it afterwards.
            if let openedBytes {
                cachedPDF = openedBytes
                // Opening one file changes nothing yet: the file on disk is the original. Without this every
                // opened document counted as unsaved work and closing it asked whether to save.
                dirty = false
            }
            if scanAfter {
                mode = .image
                adjustments.scan = true
                updatePreview()
            }
            remember(urls)
            status = "已载入 \(count) 页"
        }
    }

    // MARK: Pages

    func selectPage(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard index >= 0, index < count else { return }
        if modifiers.contains(.shift) {
            selectedPages = Set(min(selection, index)...max(selection, index))
        } else if modifiers.contains(.command) {
            if selectedPages.contains(index) && selectedPages.count > 1 { selectedPages.remove(index) } else { selectedPages.insert(index) }
        } else {
            selectedPages = [index]
        }
        readingPoint = nil
        navigationToken = UUID()
        selection = index
        selectedAnnotation = nil
        resetImage()
        scheduleRecovery()
    }

    func selectRange() {
        report {
            readingPoint = nil
            navigationToken = UUID()
            selectedPages = Set(try PageRange.parse(rangeText, count: count))
            selection = effectivePages.first ?? 0
            resetImage()
            scheduleRecovery()
        }
    }

    /// Rebuilds the document in a new page order. All per-page state follows through one remap.
    func rebuild(order: [Int], selected: Set<Int>) {
        alignMeta()
        let oldMeta = pageMeta, oldBookmarks = bookmarks, oldOutline = outlineEntries
        bookmarks = []
        outlineEntries = []
        for (index, old) in order.enumerated() {
            bookmarks += oldBookmarks.filter { $0.page == old }.map { var b = $0; b.id = UUID(); b.page = index; return b }
            outlineEntries += oldOutline.filter { $0.page == old }.map { var e = $0; e.id = UUID(); e.page = index; return e }
        }
        readingPoint = nil
        navigationToken = UUID()
        document = DocumentServices.subset(document, indexes: order)
        pageMeta = order.map { oldMeta.indices.contains($0) ? oldMeta[$0] : PageMeta() }
        ReadingServices.applyOutline(outlineEntries, to: document)
        selectedPages = selected
        selection = selected.sorted().first ?? 0
        changed()
        status = "页面操作完成，共 \(count) 页"
    }

    func move(_ delta: Int) {
        let selected = Set(effectivePages)
        guard !selected.isEmpty, (delta < 0 ? selected.min()! > 0 : selected.max()! < count - 1) else { return }
        var order = Array(0..<count)
        for index in (delta < 0 ? effectivePages : effectivePages.reversed()) { order.swapAt(index, index + delta) }
        checkpoint()
        rebuild(order: order, selected: Set(selected.map { $0 + delta }))
    }

    func movePages(before target: Int, dragged: Int) {
        guard (0...count).contains(target), (0..<count).contains(dragged) else { return }
        let moving = selectedPages.contains(dragged) ? effectivePages : [dragged]
        guard !moving.contains(target) else { return }
        var order = (0..<count).filter { !moving.contains($0) }
        let insertion = min(order.count, target - moving.filter { $0 < target }.count)
        order.insert(contentsOf: moving, at: max(0, insertion))
        guard order != Array(0..<count) else { return }
        checkpoint()
        rebuild(order: order, selected: Set(insertion..<(insertion + moving.count)))
    }

    func duplicatePages() {
        guard count > 0 else { return }
        let chosen = effectivePages
        let at = (chosen.last ?? selection) + 1
        var order = Array(0..<count)
        order.insert(contentsOf: chosen, at: at)
        checkpoint()
        rebuild(order: order, selected: Set(at..<(at + chosen.count)))
    }

    func remove() {
        let chosen = Set(effectivePages)
        guard chosen.count < count else { error = "文档至少保留一页。"; return }
        let next = min(chosen.min() ?? 0, count - chosen.count - 1)
        checkpoint()
        rebuild(order: (0..<count).filter { !chosen.contains($0) }, selected: [next])
    }

    func rotate() {
        guard count > 0 else { return }
        checkpoint()
        for i in effectivePages {
            updateMeta(i) { meta in
                if let data = meta.ocrOriginal, let source = PDFDocument(data: data), let page = source.page(at: 0) {
                    page.rotation = (page.rotation + 90) % 360
                    meta.ocrOriginal = source.dataRepresentation()
                }
                meta.ocrRegions = meta.ocrRegions?.map { line in
                    var rotated = line
                    rotated.box = CGRect(x: line.box.minY, y: 1 - line.box.maxX, width: line.box.height, height: line.box.width)
                    return rotated
                }
                meta.recipe?.adjustments.rotation += 1
                meta.draft?.rotation += 1
            }
            if let page = document.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
        changed()
    }

    // MARK: Image mode

    func resetImage() {
        imageBase = nil
        proxyBase = nil
        previewTask?.cancel()
        previewIsProxy = false
        preview = nil
        showOriginal = false
        cropMode = false
        let current = meta(selection)
        adjustments = current.draft ?? current.recipe?.adjustments ?? ImageAdjustments()
        if mode == .image, current.draft != nil || current.recipe != nil { updatePreview(markDirty: false) }
    }

    func sourceImage() throws -> CGImage {
        if let imageBase { return imageBase }
        let result: CGImage
        if let recipe = meta(selection).recipe, let source = PDFDocument(data: recipe.originalPDF), let page = source.page(at: 0) {
            result = try DocumentServices.render(page, maxDimension: 3000)
        } else if let page {
            result = try DocumentServices.render(page, maxDimension: 3000)
        } else {
            throw FolioError(message: "没有可处理的页面。")
        }
        imageBase = result
        return result
    }

    /// Small working image used while a slider is being dragged.
    private func proxyImage() throws -> CGImage {
        if let proxyBase { return proxyBase }
        let result = try DocumentServices.downscale(sourceImage(), maxDimension: 1100)
        proxyBase = result
        return result
    }

    /// `interactive` renders a fast low-resolution preview and schedules the full render shortly after.
    func updatePreview(markDirty: Bool = true, interactive: Bool = false) {
        report {
            if interactive {
                preview = NSImage(cgImage: try DocumentServices.adjusted(proxyImage(), adjustments), size: .zero)
                previewIsProxy = true
                previewTask?.cancel()
                previewTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.updatePreview(markDirty: false)
                }
            } else {
                previewTask?.cancel()
                preview = NSImage(cgImage: try DocumentServices.adjusted(sourceImage(), adjustments), size: .zero)
                previewIsProxy = false
            }
            if markDirty {
                let values = adjustments
                updateMeta(selection) { $0.draft = values }
                dirty = true
                scheduleRecovery()
            }
        }
    }

    func setCrop(_ rect: CGRect) {
        // Crop gesture coordinates refer to the currently displayed, already-cropped image.
        let previous = adjustments.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let inset = min(0.4, max(0, adjustments.crop))
        let base = previous.insetBy(dx: previous.width * inset, dy: previous.height * inset)
        adjustments.crop = 0
        adjustments.cropRect = CGRect(x: base.minX + rect.minX * base.width, y: base.minY + rect.minY * base.height, width: rect.width * base.width, height: rect.height * base.height)
        cropMode = false
        updatePreview()
    }

    func resetAdjustments() {
        adjustments = ImageAdjustments()
        updatePreview()
    }

    func detectPaper() {
        guard !busy else { return }
        report {
            let image = try sourceImage()
            busy = true
            taskLabel = "识别纸张边缘"
            progress = 0
            Task {
                do {
                    let corners = try await Task.detached { try DocumentServices.detectPaper(image) }.value
                    adjustments.perspective = corners
                    adjustments.cropRect = nil
                    updatePreview()
                    status = "已校正纸张透视，请检查预览"
                } catch {
                    self.error = error.localizedDescription
                }
                busy = false
            }
        }
    }

    func applyImage() {
        if previewIsProxy || preview == nil { updatePreview(markDirty: false) }
        guard let image = preview, let original = page else { return }
        let current = meta(selection)
        let hasText = !(original.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let annotationCount = Workspace.visibleAnnotations(on: original).count
        if current.recipe == nil && hasText {
            guard confirm("此页含有可搜索的文字", "应用图片调整会把整页转换为图片，文字层和链接将不再保留（之后可重新 OCR）。项目会保留原始页面，操作可撤销。", action: "继续应用") else { return }
        }
        if annotationCount > 0 {
            let detail = current.recipe == nil
                ? "此页的 \(annotationCount) 个标注不会出现在转换后的图片页面上。操作可撤销。"
                : "重新应用原图调整将替换当前页面上后来添加的 \(annotationCount) 个标注。原始图像会保留，操作可撤销。"
            guard confirm("页面上的标注将被移除", detail, action: "继续") else { return }
        }
        report {
            let sourceData = try current.recipe?.originalPDF ?? DocumentServices.subset(document, indexes: [selection]).dataRepresentation().unwrap("原图保存失败")
            let baseDoc = try PDFDocument(data: sourceData).unwrap("原图读取失败")
            let bounds = try baseDoc.page(at: 0).unwrap("原图读取失败").bounds(for: .cropBox)
            let maxPoints = max(bounds.width, bounds.height)
            let source = try sourceImage()
            let pointsPerPixel = maxPoints / CGFloat(max(source.width, source.height))
            guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw FolioError(message: "无法读取裁剪预览") }
            image.size = CGSize(width: CGFloat(pixels.width) * pointsPerPixel, height: CGFloat(pixels.height) * pointsPerPixel)
            guard let newPage = PDFPage(image: image) else { return }
            checkpoint()
            let values = adjustments
            updateMeta(selection) { meta in
                meta.recipe = ImageRecipe(originalPDF: sourceData, adjustments: values)
                meta.draft = nil
                meta.ocrOriginal = nil
                meta.ocrRegions = nil
            }
            document.removePage(at: selection)
            document.insert(newPage, at: selection)
            ReadingServices.applyOutline(outlineEntries, to: document)
            changed()
            status = "已应用；项目保留原始页面，可重新调整"
        }
    }

    func restoreOriginalPage() {
        guard let recipe = meta(selection).recipe, let original = PDFDocument(data: recipe.originalPDF)?.page(at: 0) else { return }
        checkpoint()
        updateMeta(selection) { $0 = PageMeta() }
        document.removePage(at: selection)
        document.insert(original, at: selection)
        ReadingServices.applyOutline(outlineEntries, to: document)
        changed()
    }

    // MARK: Export entry points

    func saveURL(type: UTType, suffix: String, name: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (name ?? title) + "." + suffix
        return panel.runModal() == .OK ? panel.url : nil
    }

    func checkDraftsForExport() -> Bool {
        guard !hasPendingDrafts else {
            error = "有图片调整尚未应用。请先应用到页面，再导出；保存项目可以保留这些调整。"
            return false
        }
        return true
    }

    func exportPDF(currentOnly: Bool = false) { openExport(format: .pdf, scope: currentOnly ? .selected : .all) }
    func exportImage(_ format: ExportFormat) { openExport(format: format, scope: .current) }

    func exportText(markdown: Bool) {
        guard checkDraftsForExport() else { return }
        let text = (0..<count).map { index in (markdown ? "## 第 \(index + 1) 页\n\n" : "") + ReadingServices.repairIdeographs(document.page(at: index)?.string ?? "") }.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "未发现文本，请先运行 OCR。"; return }
        guard let url = saveURL(type: markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText, suffix: markdown ? "md" : "txt") else { return }
        report { try text.write(to: url, atomically: true, encoding: .utf8); status = "已导出文本" }
    }

    // MARK: Annotations

    func find() { startSearch() }

    /// Marks the selected text with the chosen style and color, attaching the note text.
    func highlight() {
        guard let selected = pdfView?.currentSelection else { error = "请先在 PDF 中选中文字。扫描页需先 OCR。"; return }
        var added: [PDFAnnotation] = []
        for line in selected.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: markupStyle.subtype, withProperties: nil)
                annotation.color = markupStyle == .highlight ? markupColor.nsColor.withAlphaComponent(0.4) : markupColor.nsColor
                annotation.contents = note
                annotation.setValue(line.string ?? "", forAnnotationKey: ReadingServices.quoteKey)
                page.addAnnotation(annotation)
                added.append(annotation)
            }
        }
        recordAnnotationsAdded(added)
    }

    func compare() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        report { comparison = try DocumentServices.load(url) }
    }

    func quick(_ item: QuickTool) {
        showTools = false
        switch item {
        case .merge: open(insert: count > 0)
        case .compress: compress()
        case .ocr: ocr()
        case .imagesToPDF: open()
        case .pdfToImages: exportBatch(split: false)
        case .scan:
            let urls = pickFiles()
            guard !urls.isEmpty else { return }
            load(urls, insert: count > 0, scanAfter: true)
        case .sign:
            mode = .document
            tool = .signature
            status = "在页面上拖动手写签名；可将当前页墨迹保存到签名库"
        case .compare: compare()
        }
    }
}

enum QuickTool: String, CaseIterable, Identifiable {
    case merge = "合并 PDF"
    case compress = "压缩 PDF"
    case ocr = "OCR 识别"
    case imagesToPDF = "图片转 PDF"
    case pdfToImages = "PDF 转图片"
    case scan = "导入扫描件"
    case sign = "手写签名"
    case compare = "对照阅读"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .merge: return "多选文件，按选择顺序插入页面"
        case .compress: return "重新编码图片，保留文字与目录"
        case .ocr: return "按所选语言识别并加入可搜索文本层"
        case .imagesToPDF: return "打开图片后导出为 PDF"
        case .pdfToImages: return "全部页面导出为 PNG"
        case .scan: return "导入扫描图片，调整与增强"
        case .sign: return "在画布上手写签名"
        case .compare: return "双栏阅读，可同步翻页"
        }
    }
    var availableWithoutDocument: Bool { self == .merge || self == .imagesToPDF || self == .scan }
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw FolioError(message: message) }
        return self
    }
}
