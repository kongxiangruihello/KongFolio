import XCTest
import AppKit
import PDFKit
import CoreText
@testable import KongFolio

final class Release037Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func suite() -> UserDefaults { UserDefaults(suiteName: "KongFolio.037." + UUID().uuidString)! }
    func pdf(_ root: URL, name: String = "一本书.pdf") throws -> URL { try Release036Tests().book(root, name: name) }
    func text(_ root: URL, ext: String = "md", value: String = "原件") throws -> URL { let url = root.appendingPathComponent("笔记." + ext); try value.write(to: url, atomically: true, encoding: .utf8); return url }
    @MainActor func testShelfImportsLegacyHistoryWithoutChangingPreferences() throws {
        let root = try root(), defaults = suite(), file = try pdf(root)
        let progress = ReadingProgress(last: 2, date: Date(timeIntervalSince1970: 1800000000), pages: 4, title: "我的书")
        progress.save(path: file.path, defaults: defaults)
        let library = BookLibrary(storage: root); try library.importHistory(defaults: defaults)
        XCTAssertEqual(library.books.count, 1); XCTAssertEqual(library.books.first?.title, "我的书")
        XCTAssertEqual(ReadingProgress.load(path: file.path, defaults: defaults), progress)
        try library.importHistory(defaults: defaults); XCTAssertEqual(library.books.count, 1)
    }
    @MainActor func testShelfPersistsFavoritesCategoriesAndReflection() throws {
        let root = try root(), file = try pdf(root), library = BookLibrary(storage: root)
        let before = try Data(contentsOf: file)
        try library.add([file]); var book = try XCTUnwrap(library.books.first)
        book.favorite = true; book.category = "中国近现代史"; book.reflection = "读书心得\n第二段"
        try library.update(book)
        XCTAssertEqual(BookLibrary(storage: root).books, [book])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    @MainActor func testShelfDeduplicatesSymlinksAndRejectsUnsupportedFiles() throws {
        let root = try root(), file = try pdf(root), alias = root.appendingPathComponent("别名.pdf"), library = BookLibrary(storage: root)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        try library.add([file, alias]); XCTAssertEqual(library.books.count, 1)
        let bad = try text(root, ext: "exe"); XCTAssertThrowsError(try library.add([bad])); XCTAssertEqual(library.books.count, 1)
    }
    @MainActor func testCorruptedCatalogIsPreservedOnWriteAttempt() throws {
        let root = try root(), folder = root.appendingPathComponent("Library"), file = try pdf(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent("catalog.json"), bytes = Data("broken catalog".utf8); try bytes.write(to: index)
        let library = BookLibrary(storage: root)
        XCTAssertNotNil(library.error); XCTAssertThrowsError(try library.add([file])); XCTAssertEqual(try Data(contentsOf: index), bytes)
    }
    @MainActor func testRelinkPreservesProgressMetadataAndOldTextLink() throws {
        let root = try root(), old = try pdf(root), replacement = try pdf(root, name: "新位置.pdf"), defaults = suite(), library = BookLibrary(storage: root)
        try library.add([old]); var book = try XCTUnwrap(library.books.first); book.favorite = true; book.reflection = "心得"; book.category = "历史"; try library.update(book)
        let progress = ReadingProgress(visited: [0, 2], last: 2, date: Date(), pages: 4, x: 20, y: 60, scale: 1.8, layout: .single)
        progress.save(path: old.path, defaults: defaults)
        let shortcut = ReadingShortcut(path: old.path, title: "旧链接", mode: .fixed, position: ViewPosition(selection: 1))
        try library.register(shortcut); try FileManager.default.removeItem(at: old)
        try library.relink(path: old.path, to: replacement, defaults: defaults)
        let resolved = BookLibrary(storage: root).resolve(try ReadingShortcut.read(shortcut.link()))
        XCTAssertEqual(ReadingProgress.canonicalPath(try resolved.resolvedURL().path), ReadingProgress.canonicalPath(replacement.path)); XCTAssertEqual(resolved.mode, .fixed); XCTAssertEqual(resolved.position.selection, 1)
        let current = ReadingProgress.load(path: replacement.path, defaults: defaults)
        XCTAssertEqual(current.last, 2); XCTAssertEqual(current.scale, 1.8); XCTAssertEqual(current.visited, [0, 2]); XCTAssertEqual(current.layout, .single)
        XCTAssertTrue(library.books[0].favorite); XCTAssertEqual(library.books[0].reflection, "心得"); XCTAssertEqual(library.books[0].id, book.id)
        try library.importHistory(defaults: defaults); XCTAssertEqual(library.books.count, 1)
    }
    @MainActor func testRelinkBackToOldPathCannotMakeRedirectCycle() throws {
        let root = try root(), a = try pdf(root), b = try pdf(root, name: "第二位置.pdf"), defaults = suite(), library = BookLibrary(storage: root)
        try library.add([a]); try library.relink(path: a.path, to: b, defaults: defaults); try library.relink(path: b.path, to: a, defaults: defaults)
        let shortcut = ReadingShortcut(path: b.path, title: "书", position: ViewPosition(selection: 0))
        XCTAssertEqual(library.resolve(shortcut).path, a.path)
        XCTAssertNil(library.catalog.relocated[a.path])
    }
    @MainActor func testInvalidReplacementDoesNotAlterShelfOrReadingRecord() throws {
        let root = try root(), original = try pdf(root), defaults = suite(), library = BookLibrary(storage: root)
        try library.add([original]); let books = library.books
        let bad = root.appendingPathComponent("损坏.pdf"); try Data("invalid".utf8).write(to: bad)
        XCTAssertThrowsError(try library.relink(path: original.path, to: bad, defaults: defaults)); XCTAssertEqual(library.books, books)
    }
    @MainActor func testShortcutRegistryTracksExportsAndAvoidsDuplicateFileEntries() throws {
        let root = try root(), original = try pdf(root), library = BookLibrary(storage: root), file = root.appendingPathComponent("入口.kongfoliolink")
        let shortcut = ReadingShortcut(path: original.path, title: "书", mode: .fixed, position: ViewPosition(selection: 2))
        try shortcut.write(to: file); try library.register(shortcut, file: file); try library.register(shortcut, file: file)
        XCTAssertEqual(library.shortcuts.count, 1)
        let entry = try XCTUnwrap(library.shortcuts.first); try library.renameShortcut(entry.id, title: "新名称")
        try library.exportShortcut(entry.id, to: file)
        XCTAssertEqual(try ReadingShortcut.read(file).title, "新名称"); XCTAssertEqual(try ReadingShortcut.read(file).position.selection, 2)
        try library.removeShortcut(entry.id); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)); XCTAssertTrue(library.shortcuts.isEmpty)
    }
    @MainActor func testShortcutExternalModificationBlocksUpdate() throws {
        let root = try root(), original = try pdf(root), library = BookLibrary(storage: root), file = root.appendingPathComponent("入口.kongfoliolink")
        let shortcut = ReadingShortcut(path: original.path, title: "书", position: ViewPosition(selection: 0))
        try shortcut.write(to: file); try library.register(shortcut, file: file)
        let external = Data("external modification".utf8); try external.write(to: file)
        XCTAssertThrowsError(try library.exportShortcut(library.shortcuts[0].id, to: file)); XCTAssertEqual(try Data(contentsOf: file), external)
        // The saved baseline must be checked inside the coordinated replacement, without recapturing newer bytes.
        XCTAssertThrowsError(try shortcut.write(to: file, expected: library.shortcuts[0].baseline))
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    @MainActor func testRelinkedNativeShortcutCanUpdateOriginalDockFile() throws {
        let root = try root(), original = try pdf(root), moved = try pdf(root, name: "移动.pdf"), defaults = suite(), library = BookLibrary(storage: root), file = root.appendingPathComponent("Dock.kongfoliolink")
        let shortcut = ReadingShortcut(path: original.path, title: "书", mode: .fixed, position: ViewPosition(selection: 2))
        try shortcut.write(to: file); try library.register(shortcut, file: file)
        try library.relink(path: original.path, to: moved, defaults: defaults); try library.exportShortcut(library.shortcuts[0].id, to: file)
        let saved = try ReadingShortcut.read(file); XCTAssertEqual(saved.path, moved.path); XCTAssertEqual(saved.position.selection, 2)
    }
    @MainActor func testOldReadingURLRoutesToExplicitlyRepairedBook() async throws {
        let root = try root(), a = try pdf(root), b = try pdf(root, name: "新书.pdf"), defaults = suite(), store = WorkspaceStore(storage: root, readingDefaults: defaults)
        store.bootstrap(); try store.library.relink(path: a.path, to: b, defaults: defaults); try FileManager.default.removeItem(at: a)
        let shortcut = ReadingShortcut(path: a.path, title: "入口", mode: .fixed, position: ViewPosition(selection: 2))
        let workspace = try store.openReadingShortcut(ReadingShortcut.read(shortcut.link())); try await Release036Tests().wait(workspace)
        XCTAssertEqual(workspace.sourceURL.map { ReadingProgress.canonicalPath($0.path) }, ReadingProgress.canonicalPath(b.path)); XCTAssertEqual(workspace.selection, 2)
    }
    func testExplicitShelfSearchFindsPDFAndTextOutsideOneFolder() throws {
        let root = try root(), another = try self.root(), pdf = try pdf(root), text = try text(another, ext: "html", value: "<html><body>page one 中文资料</body></html>")
        let index = root.appendingPathComponent("index.sqlite")
        let result = try FolderSearchService.run(folder: nil, query: "page one", recursive: false, indexURL: index, includeText: true, explicitFiles: [pdf, text, pdf])
        XCTAssertEqual(result.totalFiles, 2); XCTAssertEqual(Set(result.hits.map(\.url)), [pdf, text])
        let again = try FolderSearchService.run(folder: nil, query: "page one", recursive: false, indexURL: index, includeText: true, explicitFiles: [pdf, text])
        XCTAssertTrue(again.files.allSatisfy(\.cached)); XCTAssertTrue(again.files.allSatisfy { $0.error == nil })
        let hit = try XCTUnwrap(again.hits.first { $0.url == text }); XCTAssertNotNil(try FolderSearchService.verify(hit).text)
    }
    func testMissingShelfFileReportsProblemWithoutHidingOtherResults() throws {
        let root = try root(), file = try pdf(root), missing = root.appendingPathComponent("失效.pdf")
        let result = try FolderSearchService.run(folder: nil, query: "page", recursive: false, indexURL: root.appendingPathComponent("index.sqlite"), explicitFiles: [file, missing])
        XCTAssertTrue(result.hits.count > 0); XCTAssertNotNil(result.files.first { $0.url == missing }?.error)
    }
    func testCachedBodySearchStillIncludesFreshAnnotationText() throws {
        let root = try root(), file = try pdf(root), doc = PDFDocument(url: file)!
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 50, height: 20), forType: .text, withProperties: nil); annotation.contents = "specialcomment"
        doc.page(at: 0)!.addAnnotation(annotation); try doc.dataRepresentation()!.write(to: file)
        let index = root.appendingPathComponent("index.sqlite")
        _ = try FolderSearchService.run(folder: nil, query: "page", recursive: false, indexURL: index, explicitFiles: [file])
        let result = try FolderSearchService.run(folder: nil, query: "specialcomment", recursive: false, indexURL: index, includeAnnotations: true, explicitFiles: [file])
        XCTAssertTrue(result.files[0].cached); XCTAssertEqual(result.hits.count, 1); XCTAssertEqual(result.hits.first?.category, "批注")
    }
    func testScanSearchMapsRecognizedPhraseToPageRectangles() throws {
        let root = try root(), file = try pdf(root), doc = PDFDocument(url: file)!, before = try Data(contentsOf: file)
        let box = CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.1)
        let page = try FolderSearchService.recognizedPage(doc.page(at: 0)!, index: 0) { _ in [RecognizedLine(text: "中国近现代史", box: box)] }
        var cache: [String: String] = [:]; let hit = try XCTUnwrap(FolderSearchService.matches(page, query: "近现代", limit: 10, cache: &cache).first)
        XCTAssertEqual(hit.strips?.count, 1); XCTAssertEqual(Double(hit.strips!.first!.minY), Double(box.minY), accuracy: 0.000001); XCTAssertEqual(page.category, "扫描识别（本机索引）"); XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testBookNotebookCombinesAnnotationsExcerptsAndHandwritingLinks() throws {
        let root = try root(), file = try pdf(root), doc = PDFDocument(url: file)!
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil); note.contents = "我对原文的批注"; doc.page(at: 0)!.addAnnotation(note)
        let ink = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 50, height: 20), forType: .ink, withProperties: nil); doc.page(at: 1)!.addAnnotation(ink)
        var book = LibraryBook(path: file.path, title: "书名"); book.reflection = "整体心得"
        let snapshot = try BookNotebook.make(book: book, pdf: doc.dataRepresentation()!, cards: [], outline: [OutlineEntry(page: 0, label: "第一章", depth: 0), OutlineEntry(page: 1, label: "第二章", depth: 0)])
        XCTAssertEqual(snapshot.sections.count, 2); XCTAssertTrue(snapshot.markdown.contains("整体心得")); XCTAssertTrue(snapshot.markdown.contains("我对原文的批注")); XCTAssertTrue(snapshot.markdown.contains("手写")); XCTAssertTrue(snapshot.markdown.contains("kongfolio://source"))
        let regex = try NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#)
        let match = try XCTUnwrap(regex.matches(in: snapshot.markdown, range: NSRange(location: 0, length: snapshot.markdown.utf16.count)).last)
        let link = URL(string: (snapshot.markdown as NSString).substring(with: match.range))!
        XCTAssertEqual(SourceLink.source(link)?.page, 1); XCTAssertEqual(SourceLink.source(link)?.path, file.path)
    }
    @MainActor func testCurrentNotebookUsesUnsavedAnnotationSnapshot() async throws {
        let root = try root(), file = try pdf(root), store = WorkspaceStore(storage: root, readingDefaults: suite()); store.bootstrap()
        let w = try XCTUnwrap(store.activeWorkspace); let data = try Data(contentsOf: file); w.document = PDFDocument(data: data)!; w.cachedPDF = data; w.sourceURL = file
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil); note.contents = "尚未保存的批注"; w.document.page(at: 0)!.addAnnotation(note); w.edited()
        store.openCurrentBookNotebook(); let book = try XCTUnwrap(store.notebookBook)
        let snapshot = try await BookNotebook.load(book: book, currentPDF: w.pdfData(), cards: [], outline: nil)
        XCTAssertTrue(snapshot.markdown.contains("尚未保存的批注")); XCTAssertEqual(ReadingServices.notes(PDFDocument(url: file)!).count, 0)
    }
    func testHistorySettingsValidateAndPersistLimits() throws {
        let root = try root(); var policy = HistoryPolicy(); policy.maximumEntries = 2; policy.perFileMB = 16; policy.totalMB = 256
        try policy.save(storage: root); XCTAssertEqual(HistoryPolicy.load(storage: root), policy)
        policy.maximumEntries = 1; XCTAssertThrowsError(try policy.save(storage: root))
    }
    @MainActor func testAllTextFormatsKeepOriginalAndSavedVersion() throws {
        for ext in ["md", "html", "txt"] {
            let root = try root(), file = try text(root, ext: ext), note = try MarkdownNote.open(file, storage: root)
            note.text = "修改内容"; try note.write(to: file)
            let entries = try TextVersionHistory.list(source: file, storage: root)
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(try TextVersionHistory.read(entries.last!, source: file, storage: root).text, "原件")
            XCTAssertEqual(try TextVersionHistory.read(entries.first!, source: file, storage: root).text, "修改内容")
        }
    }
    @MainActor func testTextRestorePreservesUnsavedWorkEvenWithTwoVersionLimit() throws {
        let root = try root(), file = try text(root), note = try MarkdownNote.open(file, storage: root)
        var policy = HistoryPolicy(); policy.maximumEntries = 2; try policy.save(storage: root)
        note.text = "保存版本"; try note.write(to: file)
        let original = try XCTUnwrap(TextVersionHistory.list(source: file, storage: root).last)
        note.text = "尚未保存的重要内容"; XCTAssertTrue(note.restoreTextVersion(original))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "原件")
        let versions = try TextVersionHistory.list(source: file, storage: root)
        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(try versions.contains { try TextVersionHistory.read($0, source: file, storage: root).text == "尚未保存的重要内容" })
    }
    @MainActor func testTextRestoreRefusesExternalChangesAndKeepsCurrentText() throws {
        let root = try root(), file = try text(root), note = try MarkdownNote.open(file, storage: root)
        note.text = "保存内容"; try note.write(to: file)
        let entry = try XCTUnwrap(TextVersionHistory.list(source: file, storage: root).last)
        note.text = "当前未保存"; try "外部内容".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(note.restoreTextVersion(entry)); XCTAssertEqual(note.text, "当前未保存"); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "外部内容")
    }
    @MainActor func testCorruptTextVersionCannotBeRestored() throws {
        let root = try root(), file = try text(root), note = try MarkdownNote.open(file, storage: root)
        note.text = "新内容"; try note.write(to: file)
        let entry = try XCTUnwrap(TextVersionHistory.list(source: file, storage: root).last)
        try Data("corrupt".utf8).write(to: TextVersionHistory.folder(source: file, storage: root).appendingPathComponent(entry.id.uuidString + ".json"))
        XCTAssertFalse(note.restoreTextVersion(entry)); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "新内容")
    }
    func testRetentionKeepsTwoRecentVersionsAndNeverTouchesRecovery() throws {
        let root = try root(), file = try text(root), backup = root.appendingPathComponent("Recovery-test.kfrecovery")
        try Data("important recovery".utf8).write(to: backup)
        var policy = HistoryPolicy(); policy.maximumEntries = 2; try policy.save(storage: root)
        for i in 0..<5 { try TextVersionHistory.record(TextVersionSnapshot(text: "版本\(i)", format: .markdown, resourceBasePath: nil), source: file, storage: root, label: "手动") }
        let entries = try TextVersionHistory.list(source: file, storage: root); XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(try TextVersionHistory.read(entries.first!, source: file, storage: root).text, "版本4")
        XCTAssertEqual(try TextVersionHistory.read(entries.last!, source: file, storage: root).text, "版本3")
        XCTAssertEqual(try Data(contentsOf: backup), Data("important recovery".utf8)); XCTAssertEqual(try HistoryRetention.usage(storage: root).versions, 2)
    }
    @MainActor func testPDFRestorationRetainsUnsavedWorkWithMinimumHistory() throws {
        let root = try root(), file = try pdf(root), defaults = suite(), w = try Release036Tests().workspace(root, file: file, suite: defaults)
        w.fileBaseline = try FileBaseline.capture(file)
        var policy = HistoryPolicy(); policy.maximumEntries = 2; try policy.save(storage: root)
        try DocumentHistory.protectExisting(file, storage: root)
        let original = try XCTUnwrap(DocumentHistory.list(source: file, storage: root).first)
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil); note.contents = "未保存批注"; w.document.page(at: 0)!.addAnnotation(note); w.edited()
        XCTAssertTrue(w.restoreVersion(original)); XCTAssertEqual(ReadingServices.notes(w.document).count, 0)
        let entries = try DocumentHistory.list(source: file, storage: root)
        XCTAssertTrue(try entries.contains { try DocumentHistory.read($0, source: file, storage: root).pdf != Data(contentsOf: file) })
    }
    @MainActor func testShelfCommandsWorkWithoutDocument() throws {
        let store = WorkspaceStore(storage: try root(), readingDefaults: suite())
        XCTAssertNil(store.unavailableReason(.bookshelf)); XCTAssertNil(store.unavailableReason(.shortcutManager)); XCTAssertNil(store.unavailableReason(.historySettings)); XCTAssertNotNil(store.unavailableReason(.bookNotebook))
        store.performCommand(.shortcutManager); XCTAssertTrue(store.showReadingHistory); XCTAssertEqual(store.libraryTab, 1)
    }
    func raster() throws -> Data {
        let ctx = CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        let string = NSAttributedString(string: "History reading notes 2026", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 64, nil)])
        ctx.textPosition = CGPoint(x: 50, y: 160); CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
        let doc = PDFDocument(); doc.insert(PDFPage(image: NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 600, height: 200)))!, at: 0)
        return try doc.dataRepresentation().unwrap("无法生成测试扫描页")
    }
    func testRealScanSearchRecognizesCachesAndKeepsOriginalBytes() throws {
        let root = try root(), file = root.appendingPathComponent("扫描页.pdf"), original = try raster(), index = root.appendingPathComponent("index.sqlite")
        try original.write(to: file)
        let first = try FolderSearchService.run(folder: nil, query: "History", recursive: false, indexURL: index, explicitFiles: [file], recognizeScans: true)
        XCTAssertEqual(first.hits.count, 1); XCTAssertNotNil(first.hits.first?.hit.strips)
        let second = try FolderSearchService.run(folder: nil, query: "notes", recursive: false, indexURL: index, explicitFiles: [file], recognizeScans: true)
        XCTAssertEqual(second.hits.count, 1); XCTAssertTrue(second.files[0].cached)
        XCTAssertEqual(try Data(contentsOf: file), original); XCTAssertNotNil(try FolderSearchService.verify(second.hits[0]).source.rects.first)
    }
    func testLiveScanSearchRecognizesUnsavedPDFSnapshot() throws {
        let snapshot = SearchSnapshot(id: UUID(), title: "当前扫描页", revision: UUID(), pdf: try raster())
        let root = try root()
        let result = try FolderSearchService.run(folder: nil, query: "reading", recursive: false, indexURL: root.appendingPathComponent("index.sqlite"), live: [snapshot], recognizeScans: true)
        XCTAssertEqual(result.hits.count, 1); XCTAssertEqual(result.hits.first?.tabID, snapshot.id); XCTAssertNotNil(result.hits.first?.hit.strips)
    }
    @MainActor func testShelfProjectSearchRetainsProjectMetadataWhenOpened() throws {
        let root = try root(), file = try pdf(root), w = try Release036Tests().workspace(root, file: file, suite: suite()), project = root.appendingPathComponent("书籍项目.kongfolio")
        var archive = try w.snapshot(); archive.projectPath = project.path; try archive.write(project)
        let result = try FolderSearchService.run(folder: nil, query: "page two", recursive: false, indexURL: root.appendingPathComponent("index.sqlite"), explicitFiles: [project])
        XCTAssertEqual(result.hits.count, 1)
        let verified = try FolderSearchService.verify(result.hits[0]); XCTAssertNotNil(verified.project); XCTAssertEqual(verified.source.page, 1)
        let store = WorkspaceStore(storage: root.appendingPathComponent("separate"), readingDefaults: suite()); store.bootstrap()
        try store.openFolderSearchResult(result.hits[0], verified: verified)
        XCTAssertEqual(store.activeWorkspace?.projectURL, project); XCTAssertEqual(store.activeWorkspace?.selection, 1)
    }
    @MainActor func testScanSettingsAndLibraryScopeSurviveModelRestart() throws {
        let root = try root(), model = FolderSearchModel(storage: root)
        model.scope = .library; model.recognizeScans = true; model.scanSettings.vertical = true; model.scanSettings.languages = ["zh-Hant", "en-US"]; model.remember()
        let reloaded = FolderSearchModel(storage: root)
        XCTAssertEqual(reloaded.scope, .library); XCTAssertTrue(reloaded.recognizeScans); XCTAssertTrue(reloaded.scanSettings.vertical); XCTAssertEqual(reloaded.scanSettings.languages, model.scanSettings.languages)
    }
    func testGlobalRetentionTrimsOldestAcrossPDFAndTextAndKeepsTwoPerFile() throws {
        let root = try root()
        // Simulate large versions via their recorded size, avoiding hundreds of MB in every CI run.
        for (type, suffix) in [("History", ".kongfolio"), ("TextHistory", ".json")] {
            let folder = root.appendingPathComponent(type + "/book"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var entries: [HistoryEntry] = []
            for i in 0..<3 {
                let entry = HistoryEntry(id: UUID(), created: Date(timeIntervalSince1970: Double(i)), pages: 1, label: "版本", digest: "", diskDigest: "", bytes: 50 * 1024 * 1024, automatic: false)
                entries.append(entry); try Data("synthetic payload".utf8).write(to: folder.appendingPathComponent(entry.id.uuidString + suffix))
            }
            try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"))
        }
        var policy = HistoryPolicy(); policy.totalMB = 256; try policy.save(storage: root); try HistoryRetention.apply(storage: root)
        let usage = try HistoryRetention.usage(storage: root); XCTAssertEqual(usage.versions, 5); XCTAssertEqual(usage.bytes, 250 * 1024 * 1024)
        policy.maximumEntries = 2; try policy.save(storage: root); try HistoryRetention.apply(storage: root)
        XCTAssertEqual(try HistoryRetention.usage(storage: root).versions, 4)
    }
}
