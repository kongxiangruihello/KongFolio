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
    @Published var showOCRBatchCorrection = false
    @Published var showOCRReview = false
    @Published var showPageInspection = false
    @Published var showProofreading = false
    @Published var showOutlineEditor = false
    @Published var nightReading = UserDefaults.standard.bool(forKey: Workspace.nightKey) {
        didSet { UserDefaults.standard.set(nightReading, forKey: Workspace.nightKey); applyNightReading() }
    }
    var searchCursor: Int?
    var copiedAnnotations: [PDFAnnotation] = []
    /// The outline as the reader has arranged it, kept while the tab is open so closing the editor loses nothing.
    var outlineDraft: OutlineDraft?
    @Published var showProgress = false
    @Published var readingProgress = ReadingProgress()
    var progressLoadedFor: String?
    var progressTask: Task<Void, Never>?
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
    @Published var tool = AnnotationTool.select
    @Published var note = ""
    @Published var status = "所有处理均在本机完成"
    @Published var error: String?
    @Published var busy = false { didSet { if oldValue && !busy { openDeferredFiles() } } }
    @Published var progress = 0.0
    @Published var taskLabel = ""
    @Published var dirty = false
    @Published var showTools = false
    @Published var comparison: PDFDocument?
    @Published var recognizedText = ""
    @Published var search = ""
    @Published var recentFiles: [String] = []
    @Published var recoveryStatus = ""
    @Published var pendingImports: [URL] = []
    @Published var showImportOrder = false
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var annotationColor = Color.blue { didSet { rememberDrawingStyle() } }
    @Published var showCompress = false
    @Published var showCrop = false
    var pendingWordPreviewPage: Int?
    @Published var showWordExport = false
    @Published var showBatch = false
    @Published var showVersionHistory = false
    lazy var localBatchQueue = BatchQueue(storage: AppEnvironment.isTestRun ? nil : storage)
    var batchQueue: BatchQueue { store?.batchQueue ?? localBatchQueue }
    @Published var showOCRQuality = false
    @Published var showOutlineText = false
    @Published var showReplacementRules = false
    @Published var replacementText = UserDefaults.standard.string(forKey: ReplacementRules.textKey) ?? "" {
        didSet { UserDefaults.standard.set(replacementText, forKey: ReplacementRules.textKey) }
    }
    @Published var applyReplacements = UserDefaults.standard.bool(forKey: ReplacementRules.enabledKey) {
        didSet { UserDefaults.standard.set(applyReplacements, forKey: ReplacementRules.enabledKey) }
    }
    @Published var showLowConfidence = false
    @Published var showOutlineCandidates = false
    @Published var outlineCandidates: [OutlineCandidate] = []
    @Published var outlineCandidatesChosen: Set<String> = []
    @Published var outlineCandidatesHadText = true
    @Published var ocrChecked = 0
    @Published var ocrDoubtful: [OCRPageQuality] = []
    @Published var wordOptions = WordExportOptions()
    @Published var wordScope = CropScope.all
    @Published var cropOdd = CropMargins()
    @Published var cropEven = CropMargins()
    @Published var cropSeparate = false
    @Published var cropScope = CropScope.all
    @Published var cropDetecting = false
    @Published var cropMessage = ""
    /// Fine-tuning one page at a time: the sliders then edit `cropPage` instead of the odd/even settings.
    @Published var cropSingle = false
    @Published var accuracyReference = ""
    @Published var accuracyMessage = ""
    @Published var cropPage = CropMargins()
    /// The other document shown beside this one (side-by-side reading), with the page offset kept while syncing.
    @Published var splitPartner: Workspace?
    @Published var splitSync = false
    var splitOffset = 0
    @Published var compressLevel = CompressLevel.standard
    /// Pages that carry annotations or links are left as they are instead of being redrawn.
    @Published var compressKeepMarked = true
    @Published var compressUseTarget = false
    @Published var compressTargetMB = 5.0
    /// Pages with large pictures, and how many of them carry annotations or links (set when the compress sheet opens).
    @Published var compressScan: (pictureHeavy: Int, marked: Int)?
    /// The filter chosen in the annotation list, kept while switching between tabs.
    @Published var noteFilter = AnnotationFilter()
    /// Pen and arrow line width in points; the highlighter draws a wide translucent stroke instead.
    @Published var penWidth = 2.0 { didSet { rememberDrawingStyle() } }
    @Published var penHighlighter = false { didSet { rememberDrawingStyle() } }
    /// Rectangles and ellipses get a translucent fill.
    @Published var shapeFill = false { didSet { rememberDrawingStyle() } }
    /// Entries ticked in the annotation list, for deleting or recolouring several at once.
    @Published var selectedNoteIDs: Set<String> = []
    /// Kinds of annotation hidden on the page right now ("高亮", "手写"…); not part of the file.
    @Published var hiddenKinds: Set<String> = []
    /// Styles the reader saved from the annotation bar (the built-in ones are in `AnnotationPresets.builtIn`).
    @Published var userPresets: [AnnotationPreset] = AnnotationPresets.loadUser() {
        didSet { AnnotationPresets.saveUser(userPresets) }
    }
    /// Dashed instead of solid for lines, arrows, rectangles and ellipses.
    @Published var lineDashed = false { didSet { rememberDrawingStyle() } }
    /// The drawing tools floating over the page. Off by default (reading comes first); a small button brings them up.
    @Published var showAnnotationBar = UserDefaults.standard.object(forKey: "KongFolio.annotationBar2") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(showAnnotationBar, forKey: "KongFolio.annotationBar2")
            if !showAnnotationBar, tool != .select { tool = .select }
            else if showAnnotationBar, tool == .select, drawingStylesReady {
                let next = drawingDefaults.string(forKey: "KongFolio.lastDrawingTool").flatMap(AnnotationTool.init(rawValue:)) ?? .pen
                selectTool(next, highlighter: drawingDefaults.bool(forKey: "KongFolio.lastHighlighter"))
            }
        }
    }
    /// The colour and width each tool was last used with.
    var toolStyles: [String: SavedDrawingStyle] = [:]
    var restoringDrawingStyle = false
    var drawingStylesReady = false
    var drawingDefaults = UserDefaults.standard
    var directSaveTask: Task<Void, Never>?
    var drawingInProgress = false
    @Published var showScanWorkshop = false
    @Published var signatures: [SignatureTemplate] = []
    @Published var signaturePositions: [SignaturePosition] = []
    @Published var placingSignature: SignatureTemplate?
    /// Signatures placed on pages in this session, by page, so they can be moved later (see `SignatureLayer`).
    var signatureLayers: [ObjectIdentifier: SignatureLayer] = [:]
    /// A placed signature that was picked up and is being moved, and the document as it was before.
    var movingSignature: (layer: SignatureLayer, item: PlacedSignature)?
    var moveSnapshot: ProjectArchive?
    @Published var signatureWidth = 0.28
    private var restoringBaseline = false
    @Published var projectURL: URL? { didSet { if !needsLoad, !restoringBaseline, projectURL != oldValue, let projectURL { fileBaseline = try? FileBaseline.capture(projectURL) } } }
    /// The PDF, image or text file this document was opened from; nil for merged documents and projects.
    @Published var sourceURL: URL? { didSet { if !needsLoad, !restoringBaseline, sourceURL != oldValue, let sourceURL { fileBaseline = try? FileBaseline.capture(sourceURL) } } }
    /// The tab exists but its file has not been read yet: it was opened together with many others, restored from the last
    /// session, or unloaded to free memory. Selecting the tab loads it (`ensureLoaded`).
    @Published var needsLoad = false
    var pendingView: ViewPosition?
    /// A card's source to show as soon as this tab has loaded.
    var pendingReveal: SourceRef?
    var lastActive = Date()
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
    var ocrChain: OCRChain?
    /// Pages per OCR job (a test makes it small).
    var ocrChunk = Workspace.ocrChunkSize
    /// How long the last full PDF serialization took; autosave backs off on large documents.
    var lastSerializationSeconds = 0.0
    /// Tests and scripts replace this to answer confirmation dialogs.
    static var confirmationHandler: ((_ title: String, _ detail: String) -> Bool)?
    @Published var saveConflict = false
    @Published var showTableExtraction = false
    @Published var showPDFForms = false
    @Published var showFormTemplate = false
    var fileBaseline: FileBaseline?
    @Published var tableDrafts: [TableDraftRecord] = []
    var pendingTableDraftID: UUID?
    var wordDraftDigest: String?
    var cachedPDF: Data?
    private var displayCache: (key: String, image: NSImage)?
    private var importAsInsert = false
    private var deferredOpen: (urls: [URL], insert: Bool)?
    private var autoTask: Task<Void, Never>?
    private var started = false
    private(set) var discarded = false
    private let writer = RecoveryWriter.shared
    let storage: URL
    let id = UUID()
    /// Each tab keeps its own recovery copy. The first tab uses the empty slot, which is the file name earlier versions used.
    let slot: String
    weak var store: WorkspaceStore?

    init(storage: URL? = nil, slot: String = "", drawingDefaults: UserDefaults? = nil) {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
        self.slot = slot
        self.drawingDefaults = drawingDefaults ?? (AppEnvironment.isTestRun ? UserDefaults(suiteName: "KongFolio.StyleTests." + UUID().uuidString)! : .standard)
        loadDrawingStyles()
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
    /// What the tab and the title bar show: the project file, else the opened file, else the document title.
    var displayName: String { projectURL?.lastPathComponent ?? sourceURL?.lastPathComponent ?? title }
    var displayPath: String? { (projectURL ?? sourceURL)?.path }
    /// What the status bar says while the pointer is over a file name (the system tooltip is slow and not always shown).
    @Published var pathHint: String?
    nonisolated static func pathHintText(path: String?, title: String) -> String {
        guard let path, !path.isEmpty else { return "未保存的文档：" + title }
        return "文件：" + path
    }
    func showPathHint(_ on: Bool) { pathHint = on ? Workspace.pathHintText(path: displayPath, title: title) : nil }
    func copyPath() {
        guard let path = displayPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        status = "已拷贝路径：" + path
    }
    func revealInFinder() {
        guard let url = projectURL ?? sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// Unchanged since it was opened or saved, so the file on disk is the document and no recovery copy is needed.
    var canRestoreFromFile: Bool { !dirty && (projectURL != nil || (sourceURL != nil && !hasPrivateReadingData)) }
    /// A loaded tab that can be dropped from memory and read again later without losing anything.
    var canUnload: Bool { count > 0 && !busy && canRestoreFromFile && history.isEmpty && future.isEmpty }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var canRetry: Bool { lastJob != nil && !busy }
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
        guard AppEnvironment.isInteractive else { return true }
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
        // Hidden layers are a view setting: the file is always written with every annotation showing.
        let hidden = hiddenKinds
        if !hidden.isEmpty { hiddenKinds = []; applyLayers() }
        defer { if !hidden.isEmpty { hiddenKinds = hidden; applyLayers() } }
        if let first = document.page(at: 0), !document.isEncrypted || document.allowsDocumentChanges {
            document.removePage(at: 0); document.insert(first, at: 0)
        }
        guard count > 0, let data = document.dataRepresentation() else { throw FolioError(message: "没有可保存的文档。") }
        lastSerializationSeconds = Date().timeIntervalSince(started)
        cachedPDF = data
        return data
    }

    /// Autosave waits longer when serializing the document is slow, so editing a large book stays responsive.
    var recoveryDelay: Double { min(15, max(0.7, lastSerializationSeconds * 6)) }

    func snapshot() throws -> ProjectArchive {
        if let moveSnapshot { return moveSnapshot }
        let pdf = try pdfData()
        alignMeta()
        let reading = ReadingState(bookmarks: bookmarks, outline: outlineEntries, layout: readingLayout, point: readingPoint, scale: readingScale, bibliography: bibliography.isEmpty ? nil : bibliography)
        return ProjectArchive(tableDrafts: tableDrafts.isEmpty ? nil : tableDrafts, wordDraft: wordDraftArchive, fileBaseline: fileBaseline, reading: reading, signatureEdits: signatureEditArchives, ocrOriginals: ocrOriginals, ocrRegions: ocrRegions, sourcePath: sourceURL?.path, pdf: pdf, title: title, selection: selection, selectedPages: Set(effectivePages), mode: .document, recipes: [:], drafts: [:], dirty: dirty, projectPath: projectURL?.path)
    }

    func restore(_ archive: ProjectArchive, keepProjectURL: Bool = false) throws {
        try archive.validate()
        document = try PDFDocument(data: archive.pdf).unwrap("项目中的 PDF 无法读取")
        restoreSignatureEdits(archive.signatureEdits ?? [:])
        ReadingServices.applyOutline(archive.reading?.outline ?? ReadingServices.outline(document), to: document)
        cachedPDF = archive.pdf
        bookmarks = archive.reading?.bookmarks ?? []
        outlineEntries = archive.reading?.outline ?? ReadingServices.outline(document)
        readingLayout = archive.reading?.layout ?? .continuous
        readingPoint = archive.reading?.point
        readingScale = archive.reading?.scale
        bibliography = archive.reading?.bibliography ?? Bibliography()
        pageMeta = (0..<document.pageCount).map { index in
            PageMeta(ocrOriginal: archive.ocrOriginals?[index], ocrRegions: archive.ocrRegions?[index])
        }
        navigationToken = UUID()
        layoutRevision = UUID()
        pageVersions = [:]
        thumbnails.clear()
        searchTask?.cancel()
        searchResults = []
        annotationNotes = []
        title = archive.title
        // Recovery already carries its baseline. Reading the current cloud file here can block launch
        // and would establish the wrong version before the saved baseline is restored below.
        restoringBaseline = true
        defer { restoringBaseline = false }
        if !keepProjectURL { sourceURL = archive.sourcePath.map { URL(fileURLWithPath: $0) } }
        selection = archive.selection
        selectedPages = archive.selectedPages
        dirty = archive.dirty
        if !keepProjectURL { projectURL = archive.projectPath.map { URL(fileURLWithPath: $0) } }
        revision = UUID()
        if !keepProjectURL { fileBaseline = archive.fileBaseline }
        tableDrafts = archive.tableDrafts ?? []
        try persistTableDrafts()
        restoreWordDraft(archive.wordDraft, sourceDigest: OCRPageCache.digest(archive.pdf))
        saveConflict = false
        selectedAnnotation = nil
    }

    func bootstrap() {
        guard !started else { return }
        started = true
        recentFiles = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: storage.appendingPathComponent("Recent.json")))) ?? []
        signatures = (try? JSONDecoder().decode([SignatureTemplate].self, from: Data(contentsOf: storage.appendingPathComponent("Signatures.json")))) ?? []
        loadSignaturePositions()
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
        guard dirty || hasPrivateReadingData else {
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
            if self.drawingInProgress { self.scheduleRecovery(); return }
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
        }
        scheduleRecovery()
        scheduleDirectSave()
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

    @discardableResult func saveProject(asNew: Bool = false, background: Bool = true, automatic: Bool = false) -> Bool {
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
            let expected = try baseline(for: url)
            try expected.verify(url)
            var archive = try snapshot()
            archive.projectPath = url.path
            archive.dirty = false
            if background {
                busy = true
                progress = 0
                taskLabel = "保存项目…"
                let captured = archive
                let backups = backupFolder
                let historyStorage = storage
                Task {
                    defer { busy = false }
                    do {
                        let result = try await Task.detached { () -> (Error?, FileBaseline) in
                            try DocumentHistory.protectExisting(url, storage: historyStorage)
                            let failure = ProjectBackup.preserve(url, in: backups)
                            let saved = try expected.writing(url) { try captured.write($0) }
                            do { try DocumentHistory.record(captured, source: url, storage: historyStorage, label: automatic ? "自动保存项目" : "保存项目", automatic: automatic) }
                            catch { return (error, saved) }
                            return (failure, saved)
                        }.value
                        projectURL = url
                        fileBaseline = result.1; saveConflict = false
                        dirty = false
                        try persistWordDraft(); try persistTableDrafts()
                        remember([url])
                        scheduleRecovery()
                        status = Workspace.savedStatus(result.0)
                    } catch {
                        handleSaveError(error)
                    }
                }
                return true
            }
            try DocumentHistory.protectExisting(url, storage: storage)
            var backupError = ProjectBackup.preserve(url, in: backupFolder)
            let saved = try expected.writing(url) { try archive.write($0) }
            do { try DocumentHistory.record(archive, source: url, storage: storage, label: automatic ? "自动保存项目" : "保存项目", automatic: automatic) }
            catch { backupError = backupError ?? error }
            projectURL = url
            fileBaseline = saved; saveConflict = false
            dirty = false
            try persistWordDraft(); try persistTableDrafts()
            remember([url])
            scheduleRecovery()
            status = Workspace.savedStatus(backupError)
            return true
        } catch {
            handleSaveError(error)
            return false
        }
    }

    func confirmReplace() -> Bool {
        guard dirty else { return true }
        return saveDirectly()
    }

    /// Asks where to put a PDF of the document and writes it; false when cancelled or when it failed.
    func saveAsPDFBeforeLeaving() -> Bool {
        guard checkDraftsForExport() else { return false }
        guard let url = saveURL(type: .pdf, suffix: "pdf") else { return false }
        do { try writePDFCopy(to: url) } catch {
            self.error = "保存 PDF 失败：\(error.localizedDescription)"
            return false
        }
        status = "已保存为 PDF：\(url.lastPathComponent)"
        return true
    }

    /// The document as a plain PDF (page content, annotations, outline and recognised text), written through a temporary file.
    func writePDFCopy(to url: URL) throws {
        let data = try pdfData()
        let staging = url.deletingLastPathComponent().appendingPathComponent(".KongFolio-\(UUID().uuidString.prefix(8)).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: url) }
    }

    /// Lets go of the unsaved work: no recovery copy is kept and the document counts as clean.
    func discardWork() -> Bool {
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
    }

    func prepareToClose() -> Bool {
        captureReadingPosition()
        guard !busy else { status = "请等待任务完成或点击取消任务"; return false }
        if dirty {
            guard confirmReplace() else { return false }
            // A discarded recovery file must not be recreated during termination.
            if discarded { return true }
        }
        if count == 0 { return true }
        if canRestoreFromFile {
            // The file (or saved project) is this document; the session file remembers where to find it.
            autoTask?.cancel()
            try? writer.flush(nil, to: recoveryURL)
            return true
        }
        return flushRecovery()
    }

    /// Empties the workspace. With `keepingSource` the file it came from stays known, so the tab can load it again.
    private func clearDocument(keepingSource: Bool) {
        try? persistWordDraft()
        try? persistTableDrafts()
        tableDrafts = []; pendingTableDraftID = nil
        wordOptions.editedBlocks = nil; wordOptions.blockBaselines = nil; wordOptions.editedSourceDigest = nil; wordOptions.editedText = nil; wordOptions.editedFromRevision = nil; wordDraftDigest = nil
        saveConflict = false; fileBaseline = nil
        directSaveTask?.cancel()
        searchTask?.cancel(); estimateTask?.cancel()
        document = PDFDocument(); cachedPDF = nil
        pageMeta = []; selection = 0; selectedPages = [0]; rangeText = ""
        title = "未命名文档"; tool = .select; note = ""
        bookmarks = []; bookmarkName = ""; outlineEntries = []; bibliography = Bibliography()
        search = ""; searchResults = []; searchMessage = ""; annotationNotes = []
        readingPoint = nil; readingScale = nil
        hiddenKinds = []; outlineDraft = nil; selectedAnnotation = nil; comparison = nil; recognizedText = ""
        showOCRReview = false; reviewSelection = -1; exportEstimate = nil
        history.removeAll(); future.removeAll(); lastJob = nil
        if !keepingSource { projectURL = nil; sourceURL = nil; needsLoad = false; pendingView = nil }
        dirty = false; discarded = false
        thumbnails.clear(); pageVersions = [:]
        layoutRevision = UUID(); navigationToken = UUID(); revision = UUID()
        recoveryStatus = ""
    }

    func currentViewPosition() -> ViewPosition {
        captureReadingPosition()
        return ViewPosition(selection: selection, x: readingPoint.map { Double($0.x) }, y: readingPoint.map { Double($0.y) }, scale: readingScale)
    }

    /// Frees the memory of an unchanged document; the tab stays and reads the file again when it is selected.
    func unload() {
        guard canUnload else { return }
        pendingView = currentViewPosition()
        autoTask?.cancel()
        writer.discard(recoveryURL)
        clearDocument(keepingSource: true)
        needsLoad = true
        status = "已释放内存：再次选中此标签页时重新读取"
    }

    /// Reads the file of a tab that was waiting (see `needsLoad`).
    func ensureLoaded() {
        guard needsLoad, count == 0, !busy, let url = projectURL ?? sourceURL else { return }
        needsLoad = false
        load([url])
    }

    /// Drops what a waiting tab was going to load (closing it, or giving up on a file that cannot be read).
    func forgetSource() {
        projectURL = nil; sourceURL = nil; needsLoad = false; pendingView = nil
    }

    private func applyPendingView() {
        if let position = pendingView {
            pendingView = nil
            selection = max(0, min(position.selection, count - 1))
            selectedPages = [selection]
            readingPoint = position.point
            readingScale = position.scale
            navigationToken = UUID()
        }
        if let reveal = pendingReveal {
            pendingReveal = nil
            revealWhenReady(reveal)
        }
    }

    /// How this tab is written to the session file; nil for a tab with nothing to restore.
    var sessionEntry: SessionEntry? {
        if count > 0 {
            guard canRestoreFromFile else { return SessionEntry(slot: slot, kind: .recovery) }
            return fileEntry(position: currentViewPosition())
        }
        return needsLoad ? fileEntry(position: pendingView) : nil
    }

    private func fileEntry(position: ViewPosition?) -> SessionEntry? {
        if let url = projectURL { return SessionEntry(slot: slot, kind: .project, path: url.path, position: position) }
        if let url = sourceURL { return SessionEntry(slot: slot, kind: .file, path: url.path, position: position) }
        return nil
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
        clearDocument(keepingSource: false)
        status = "已关闭“\(closed)”"
        return true
    }

    // MARK: Opening

    func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        var types: [UTType] = [.pdf, .image, .html, .plainText, UTType(exportedAs: "com.kongfolio.project")]
        types += TextImport.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    func open(insert: Bool = false, merge: Bool = false) {
        guard !busy else { return }
        let urls = pickFiles()
        guard !urls.isEmpty else { return }
        openSelected(urls, insert: insert, merge: merge)
    }

    /// Several files are opened side by side, one tab each. Only an explicit merge (or inserting pages into the
    /// current document) asks for an order and combines them.
    func openSelected(_ urls: [URL], insert: Bool, merge: Bool = false) {
        if !insert, !merge, let store {
            store.openEach(urls)
            return
        }
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
        let files = urls.filter { $0.isFileURL && (["pdf", "kongfolio"].contains($0.pathExtension.lowercased()) || TextImport.handles($0) || ImageImport.handles($0)) }
        guard !files.isEmpty else { error = "支持拖入 PDF、图片、Markdown、HTML、TXT 或 KongFolio 项目。"; return }
        let isProject = files.contains { $0.pathExtension.lowercased() == "kongfolio" }
        var insert = false
        if count > 0, !isProject, AppEnvironment.isInteractive {
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

    func load(_ urls: [URL], insert: Bool = false, prepared: ImportPayload? = nil) {
        guard !urls.isEmpty else { return }
        // A document that is already open stays open: new files go to a new tab. Inserting pages and the
        // prepared (already read) payload of a tab's own import are not routed.
        if !insert, prepared == nil, count > 0, let store {
            store.openInNewTab(urls)
            return
        }
        if busy {
            // Opening from Finder while a task runs used to be dropped silently; queue it instead.
            deferredOpen = (urls, insert)
            status = "当前任务完成后将打开：\(urls.map(\.lastPathComponent).joined(separator: "、"))"
            return
        }
        if prepared == nil { startImport(urls, insert: insert); return }
        report {
            if urls.contains(where: { $0.pathExtension.lowercased() == "kongfolio" }) {
                guard urls.count == 1, !insert else { throw FolioError(message: "请单独打开 KongFolio 项目；合并时使用 PDF。") }
                guard case .project(let archive) = prepared else { throw FolioError(message: "项目读取失败") }
                guard confirmReplace() else { return }
                try restore(archive)
                discarded = false
                projectURL = urls[0]
                sourceURL = nil
                fileBaseline = archive.fileBaseline
                if archive.wordDraft == nil { loadWordDraft() }
                if archive.tableDrafts == nil { loadTableDrafts() }
                history.removeAll()
                future.removeAll()
                remember(urls)
                scheduleRecovery()
                applyPendingView()
                status = "项目已打开"
                store?.loadedTabsChanged()
                return
            }
            guard case .documents(let data) = prepared else { throw FolioError(message: "文档读取失败") }
            var openedBytes: Data?
            // A file marked "no modification" would silently drop annotations on saving; it is rebuilt as an unrestricted copy.
            var rebuilt = false
            let loaded = try data.map { bytes -> PDFDocument in
                let original = try PDFDocument(data: bytes).unwrap("文档读取失败")
                let usable = DocumentServices.unrestricted(original)
                if usable !== original { rebuilt = true }
                return usable
            }
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
                if loaded.count == 1, let bytes = data.first {
                    restoreSignatureEdits(SignaturePersistence.read(pdf: urls[0], bytes: bytes, storage: storage))
                } else { signatureLayers = [:] }
                pageMeta = Array(repeating: PageMeta(), count: combined.pageCount)
                title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "合并文档"
                selection = 0
                selectedPages = [0]
                history.removeAll()
                future.removeAll()
                projectURL = nil
                if loaded.count == 1, !rebuilt { openedBytes = data.first }
                sourceURL = loaded.count == 1 ? urls[0] : nil
            }
            readingPoint = nil
            readingScale = nil
            navigationToken = UUID()
            discarded = false
            recognizedText = ""
            changed()
            // The opened bytes are the document. Without this, the first autosave (and the first search)
            // serialized the whole file on the main thread. `changed()` clears the cache, so set it afterwards.
            if let openedBytes { cachedPDF = openedBytes }
            // Opening one file changes nothing yet: the file on disk is the original (or, for a file marked "no modification",
            // an editable copy of it). Without this every opened document counted as unsaved work and closing it asked
            // whether to save.
            if !insert {
                wordOptions.editedBlocks = nil; wordOptions.blockBaselines = nil; wordOptions.editedSourceDigest = nil; wordOptions.editedText = nil; wordOptions.editedFromRevision = nil; wordDraftDigest = nil
                if loaded.count == 1 {
                    dirty = false
                    fileBaseline = try FileBaseline.capture(urls[0], data: urls[0].pathExtension.lowercased() == "pdf" ? data[0] : nil)
                } else { fileBaseline = nil }
                saveConflict = false; loadWordDraft(); loadTableDrafts()
            }
            // A book opened on its own (not to a card's source, a link or a restored tab) goes on where it was last read (0.34).
            var resumed: Int?
            if !insert, loaded.count == 1, pendingView == nil, pendingReveal == nil, AppInterface.resumeReading,
               let page = ReadingProgress.load(path: urls[0].path).resumePage(pageCount: count) {
                pendingView = ViewPosition(selection: page, x: nil, y: nil, scale: nil)
                resumed = page
            }
            applyPendingView()
            remember(urls)
            status = "已载入 \(count) 页" + (rebuilt ? "（此文件带“禁止修改”限制，已转成可编辑文档；修改后自动保存）" : "")
                + (resumed.map { "；回到上次读到的第 \($0 + 1) 页" } ?? "")
            store?.loadedTabsChanged()
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
        scheduleRecovery()
    }

    func selectRange() {
        report {
            readingPoint = nil
            navigationToken = UUID()
            selectedPages = Set(try PageRange.parse(rangeText, count: count))
            selection = effectivePages.first ?? 0
            scheduleRecovery()
        }
    }

    /// Rebuilds the document in a new page order. All per-page state follows through one remap.
    func rebuild(order: [Int], selected: Set<Int>) {
        alignMeta()
        let oldSignatures = signatureEditArchives
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
        var remappedSignatures: [Int: SignatureEditArchive] = [:]
        for (index, old) in order.enumerated() { remappedSignatures[index] = oldSignatures[old] }
        restoreSignatureEdits(remappedSignatures)
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
            }
            if let page = document.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
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
        // Whatever is exported, hidden annotation types come back first: a layer is only a view setting.
        showAllLayers()
        return true
    }

    func exportPDF(currentOnly: Bool = false) { openExport(format: .pdf, scope: currentOnly ? .selected : .all) }

    func exportText(markdown: Bool) {
        guard checkDraftsForExport() else { return }
        let text = (0..<count).map { index in
            // Vertical pages read from their recognition record (right-to-left columns); others from the text layer.
            let body = ReplacementRules.apply(applyReplacements ? ReplacementRules.parse(replacementText) : [],
                to: OrderedText.verticalColumns(meta(index).ocrRegions ?? []).map { $0.map { ReadingServices.repairIdeographs($0) }.joined() }
                    ?? ReadingServices.repairIdeographs(document.page(at: index)?.string ?? ""))
            return (markdown ? "## 第 \(index + 1) 页\n\n" : "") + body
        }.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "未发现文本，请先运行 OCR。"; return }
        guard let url = saveURL(type: markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText, suffix: markdown ? "md" : "txt") else { return }
        report { try text.write(to: url, atomically: true, encoding: .utf8); status = "已导出文本" }
    }

    // MARK: Annotations

    func find() { startSearch() }

    /// Marks the selected text with the chosen style and color, attaching the note text.
    func highlight() {
        guard pdfView?.currentSelection != nil else { error = "请先在 PDF 中选中文字。扫描页需先 OCR。"; return }
        mark(style: markupStyle, color: markupColor, note: note)
    }

    /// Marks the current selection (floating toolbar, menu, shortcuts) and clears the selection.
    /// With `annotate`, the new mark is selected so its note can be typed in the inspector.
    @discardableResult
    func mark(style: MarkupStyle, color: MarkupColor, note text: String = "", annotate: Bool = false) -> [PDFAnnotation] {
        guard let selected = pdfView?.currentSelection, !(selected.string ?? "").isEmpty else { error = "请先在 PDF 中选中文字。扫描页需先 OCR。"; return [] }
        var added: [PDFAnnotation] = []
        for line in selected.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: style.subtype, withProperties: nil)
                annotation.color = style == .highlight ? color.nsColor.withAlphaComponent(0.4) : color.nsColor
                annotation.contents = text
                annotation.setValue(line.string ?? "", forAnnotationKey: ReadingServices.quoteKey)
                page.addAnnotation(annotation)
                added.append(annotation)
            }
        }
        recordAnnotationsAdded(added)
        pdfView?.clearSelection()
        if annotate, let first = added.first {
            selectAnnotation(first)
            status = "已标记，可在右侧输入批注"
        }
        return added
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
        case .ocrCorrection: DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.showOCRBatchCorrection = true }
        case .sign:
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
    case ocrCorrection = "OCR 批量纠错"
    case sign = "手写签名"
    case compare = "对照阅读"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .merge: return "多选文件，按选择顺序插入页面"
        case .compress: return "重新编码图片，保留文字与目录"
        case .ocr: return "按所选语言识别并加入可搜索文本层"
        case .ocrCorrection: return "预览错字命中，勾选后同步修正文字层"
        case .sign: return "在画布上手写签名"
        case .compare: return "双栏阅读，可同步翻页"
        }
    }
    var availableWithoutDocument: Bool { self == .merge }
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw FolioError(message: message) }
        return self
    }
}
