import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor final class ResearchController: ObservableObject {
    @Published var busy = false
    @Published var message = ""
    @Published var pairs: [PageReassociation] = []
    @Published var correctionHits: [OCRRuleHit] = []
    @Published var academicText = "" { didSet { if !restoringAcademic { scheduleAcademicDraft() } } }
    var restoringAcademic = false
    var academicStorage: URL?
    var academicSource = "unsaved"
    var academicSourceDigest: String?
    var draftTask: Task<Void, Never>?
    @Published var academicWarnings: [String] = []
    @Published var sampleOriginal: PDFDocument?
    @Published var sampleResult: PDFDocument?
    @Published var trialFolder: URL?
    var academicReviewDigest: String?
    var correctionRevision: UUID?
    var oldArchive: ProjectArchive?
    var newPDF: Data?
    var worker: Task<Void, Never>?
    func perform(_ operation: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }; busy = true; message = "正在处理…"
        worker = Task { [weak self] in
            defer { self?.busy = false; self?.worker = nil }
            do { self?.message = try await operation() } catch { self?.message = error.localizedDescription }
        }
    }
    func attachAcademicDraft(_ store: WorkspaceStore) {
        flushAcademicDraft()
        academicStorage = store.storage
        academicSource = store.commandWorkspace?.displayPath ?? store.activeNote?.fileURL?.path ?? "unsaved"
        academicSourceDigest = store.commandWorkspace?.fileBaseline?.digest ?? store.activeNote?.fileBaseline?.digest
        restoringAcademic = true
        defer { restoringAcademic = false }
        do {
            if let draft = try AcademicDraftStore.read(source: academicSource, storage: store.storage) {
                academicText = draft.text
                message = draft.digest == academicSourceDigest ? "已恢复学术整理草稿" : "已恢复学术整理草稿；原文版本可能变化，请核对后导出"
            } else { academicText = "" }
        } catch { message = "草稿无法读取，原稿保留：" + error.localizedDescription }
    }
    private func scheduleAcademicDraft() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            self?.flushAcademicDraft()
        }
    }
    func flushAcademicDraft() {
        draftTask?.cancel(); draftTask = nil
        guard let storage = academicStorage else { return }
        do { try AcademicDraftStore.write(.init(text: academicText, source: academicSource, digest: academicSourceDigest, modified: Date()), storage: storage) }
        catch { message = "学术整理稿尚未保存：" + error.localizedDescription }
    }
    func closeGroup(_ store: WorkspaceStore, group: ReadingGroup) {
        perform { await store.closeReadingGroup(group) ? "阅读组已关闭" : "保存未完成，阅读组仍保留" }
    }
    func indexAnnotations(_ store: WorkspaceStore) {
        perform { try await store.indexResearchAnnotations(); return "批注索引已更新；无法读取的原件保留旧索引" }
    }
    func chooseFile(pdfOnly: Bool = false) -> URL? {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if pdfOnly { panel.allowedContentTypes = [.pdf] }
        return panel.runModal() == .OK ? panel.url : nil
    }
    func destination(suffix: String, name: String) -> URL? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: suffix) ?? .data]; panel.nameFieldStringValue = name + "." + suffix
        return panel.runModal() == .OK ? panel.url : nil
    }
    func backup(_ store: WorkspaceStore, includeOriginals: Bool) {
        guard let destination = destination(suffix: "kfresearchbackup", name: "KongFolio-阅读资料备份") else { return }
        perform {
            guard await store.finishPendingSaves() else { throw FolioError(message: "请先处理未保存的文档") }
            for note in store.tabs.compactMap(\.note) where note.dirty { try note.writeBackup() }
            if store.board.hasContent { try store.board.writeBackup() }
            try store.library.importHistory(defaults: store.readingDefaults)
            let opened = store.tabs.compactMap { tab in tab.workspace?.historySource ?? tab.note?.fileURL }.filter { BookLibrary.supports($0) && FileManager.default.fileExists(atPath: $0.path) }
            if !opened.isEmpty { try store.library.add(opened) }
            let library = store.library.catalog, research = store.research.state, root = store.storage
            let progress = try Dictionary(uniqueKeysWithValues: ReadingProgress.history(defaults: store.readingDefaults).map { ($0.path, try JSONEncoder().encode($0.progress)) })
            let expected = try FileBaseline.capture(destination)
            try await Task.detached {
                let backup = try ResearchBackup.capture(storage: root, catalog: library, research: research, progress: progress, includeOriginals: includeOriginals)
                try backup.write(destination, expected: expected)
            }.value
            return "备份完成：" + destination.lastPathComponent
        }
    }
    func restoreBackup(_ store: WorkspaceStore) {
        guard let file = chooseFile() else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        perform {
            let result = try await Task.detached { try ResearchBackup.read(file).restore(in: folder) }.value
            let support = result.root.appendingPathComponent("AppData")
            let catalog = try JSONDecoder().decode(BookLibrary.Catalog.self, from: Data(contentsOf: support.appendingPathComponent("Library/catalog.json")))
            let research = try JSONDecoder().decode(ResearchStore.State.self, from: Data(contentsOf: support.appendingPathComponent("Research/catalog.json")))
            try store.library.importRestoredCatalog(catalog)
            try store.research.merge(research)
            let target = store.storage
            let copied = try await Task.detached { () throws -> Int in
                var copied = 0
                for folder in ResearchBackup.allowedFolders where folder != "Library" && folder != "Research" {
                    let source = support.appendingPathComponent(folder).resolvingSymlinksInPath().standardizedFileURL, destination = target.appendingPathComponent(folder)
                    guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                    for case let file as URL in enumerator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                        let normalized = file.standardizedFileURL.path
                        guard normalized.hasPrefix(source.path + "/") else { throw FolioError(message: "恢复资料路径无效") }
                        let out = destination.appendingPathComponent(String(normalized.dropFirst(source.path.count + 1)))
                        if FileManager.default.fileExists(atPath: out.path) { continue }
                        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: file, to: out); copied += 1
                    }
                }
                return copied
            }.value
            let progress = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: result.root.appendingPathComponent("ReadingProgress.plist")))
            for (path,bytes) in progress { try JSONDecoder().decode(ReadingProgress.self, from: bytes).save(path: path, defaults: store.readingDefaults) }
            return "已恢复并载入书架（\(copied) 份伴随资料）；缺失原件 \(result.missing.count) 份。独立恢复目录：" + result.root.path + (result.missing.isEmpty ? "" : "\n缺失：\n" + result.missing.joined(separator: "\n"))
        }
    }
    func prepareReassociation(_ w: Workspace) {
        guard let file = chooseFile(pdfOnly: true) else { return }
        perform {
            let old = try w.snapshot()
            let (bytes,pairs) = try await Task.detached { () throws -> (Data,[PageReassociation]) in
                let bytes = try Data(contentsOf: file); return (bytes,try ReadingReassociation.propose(old: old.pdf, new: bytes))
            }.value
            self.oldArchive = old; self.newPDF = bytes; self.pairs = pairs
            self.sampleOriginal = PDFDocument(data: old.pdf); self.sampleResult = PDFDocument(data: bytes)
            return "请逐页核对并修改对应页；留空的旧页不迁移。确认后生成独立文档。"
        }
    }
    func applyReassociation(_ store: WorkspaceStore, includeAnnotations: Bool) {
        perform {
            guard let old = self.oldArchive, let bytes = self.newPDF else { throw FolioError(message: "请先选择新版本") }
            let mapping = Dictionary(uniqueKeysWithValues: self.pairs.compactMap { pair in pair.proposed.map { (pair.old,$0) } })
            let result = try await Task.detached { try ReadingReassociation.apply(old, to: bytes, mapping: mapping, includeAnnotations: includeAnnotations) }.value
            let w = store.addWorkspace(); try w.restore(result); w.title += "-重新关联"; w.scheduleRecovery()
            return "已生成独立文档，原件及旧校对资料保留；请另存保存。"
        }
    }
    func previewCorrections(_ store: WorkspaceStore) {
        guard let w = store.commandWorkspace, let path = w.displayPath else { message = "请打开有 OCR 记录的原书"; return }
        let project = store.library.book(path: path)?.category ?? ""
        correctionHits = OCRBatchCorrection.matches(regions: w.ocrRegions, rules: store.research.rules(path: path, project: project)); correctionRevision = w.revision
        message = "找到 \(correctionHits.count) 处。核对后应用，可用撤销回退；原始识别文字保留。"
    }
    func loadAcademic(_ store: WorkspaceStore) {
        perform {
            if let note = store.activeNote { self.academicText = note.text; return "已载入当前文字，可补充脚注、尾注和题注" }
            guard let w = store.commandWorkspace, w.count > 0 else { throw FolioError(message: "请打开文档") }
            let bytes = try w.pdfData(), pages = Array(0..<w.count), options = w.wordOptions, regions = w.ocrRegions
            let labels = pages.map { store.research.displayLabel(path: w.displayPath ?? "", page: $0, fallback: String($0+1)) }
            self.academicText = try await Task.detached {
                let doc = try PDFDocument(data: bytes).unwrap("无法读取 PDF")
                let prepared = try WordCleanup.inspect(doc, pages: pages, options: options, regions: regions, sourceDigest: OCRPageCache.digest(bytes))
                return prepared.pages.map { page in
                    var text = ":::page " + labels[page.index] + "\n\n"
                    for block in page.blocks ?? page.paragraphs.map(WordPreparedBlock.paragraph) {
                        switch block {
                        case .paragraph(let p): text += String(repeating: "#", count: p.heading) + (p.heading > 0 ? " " : "") + p.text + "\n\n"
                        case .table(let rows), .spanningTable(let rows, _): text += Self.markdownTable(rows) + "\n\n"
                        }
                    }
                    return text
                }.joined(separator: "\n")
            }.value
            return "正文已载入。脚注 [^1]，尾注 [~1]；底部定义 [^1]: 内容。:::caption 添加题注，:::page 添加原页码和分页。"
        }
    }
    nonisolated static func markdownTable(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        let columns = max(1, rows.map(\.count).max() ?? first.count)
        func line(_ cells: [String]) -> String {
            "| " + (0..<columns).map { ($0 < cells.count ? cells[$0] : "").replacingOccurrences(of: "|", with: "&#124;").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        return ([line(first), line(Array(repeating: "---", count: columns))] + rows.dropFirst().map(line)).joined(separator: "\n")
    }
    func exportAcademic(reviewed: Bool = false) {
        do { academicWarnings = try AcademicMarkup.parse(academicText).warnings } catch { message = error.localizedDescription; return }
        let digest = OCRPageCache.digest(Data(academicText.utf8))
        if !academicWarnings.isEmpty, !reviewed || academicReviewDigest != digest {
            academicReviewDigest = digest; message = "发现待核文字，请先核对下方列表，再点击“已核对，继续导出”"; return
        }
        guard let url = destination(suffix: "docx", name: "学术整理稿") else { return }
        perform {
            let text = self.academicText, expected = try FileBaseline.capture(url)
            let protected = self.academicSource == "unsaved" ? nil : URL(fileURLWithPath: self.academicSource)
            try await Task.detached {
                let parsed = try AcademicMarkup.parse(text), document = try RichTextDocument(parsed.text, format: .markdown, baseURL: protected?.deletingLastPathComponent())
                try DocumentTaskOutput.write(to: url, expected: expected, protectedSource: protected) { try RichTextWord.write(document, to: $0, academic: parsed) }
            }.value
            return "Word 已导出；脚注、尾注、题注和原页码已保留。"
        }
    }
    func trial(_ store: WorkspaceStore, recipe: WorkRecipe, range: String) {
        perform {
            guard let w = store.commandWorkspace, w.count > 0 else { throw FolioError(message: "请打开待试做的 PDF") }
            let source = try w.pdfData(), pages = try PageRange.parse(range, count: w.count)
            let folder = store.storage.appendingPathComponent("Trials").appendingPathComponent(UUID().uuidString)
            let replacements = w.applyReplacements ? ReplacementRules.parse(w.replacementText) : []
            guard !pages.isEmpty, pages.count <= 5 else { throw FolioError(message: "试做请选择 1–5 页") }
            let result = try await Task.detached { () throws -> (Data,Data,String) in
                let doc = try PDFDocument(data: source).unwrap("无法读取 PDF")
                let subset = try DocumentServices.subset(doc, indexes: pages).dataRepresentation().unwrap("无法生成试做页")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                do {
                    var plan = recipe; plan.pageRange = ""; plan.writePDF = true
                    let word = plan.word == nil ? nil : folder.appendingPathComponent("试做-Word.docx")
                    let result = try BatchPipeline.process(subset, recipe: plan, replacements: replacements, wordURL: word)
                    let output = try result.pdf.unwrap("试做没有生成 PDF")
                    try output.write(to: folder.appendingPathComponent("试做-PDF.pdf"), options: .atomic)
                    for (name,data) in result.chapters { try data.write(to:folder.appendingPathComponent(name),options:.atomic) }
                    return (subset,output,"试做完成：\(pages.count) 页 → \(result.pages) 页；\(ByteCountFormatter.string(fromByteCount: Int64(output.count), countStyle: .file))" + (word == nil ? "" : "；含 Word 试做稿") + "。可查看输出文件，未修改原文件或启动整批处理。")
                } catch { try? FileManager.default.removeItem(at:folder); throw error }
            }.value
            self.sampleOriginal = PDFDocument(data: result.0); self.sampleResult = PDFDocument(data: result.1); self.trialFolder = folder
            return result.2
        }
    }
}
