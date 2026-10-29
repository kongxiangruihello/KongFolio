import XCTest
import PDFKit
import AppKit
@testable import KongFolio

final class Release038Tests: XCTestCase {
    func root() throws -> URL { try Release027Tests().folder() }
    func pdf(_ root: URL, name: String = "book.pdf", pages: Int = 2) throws -> URL {
        let doc = PDFDocument(); for _ in 0..<pages { doc.insert(PDFPage(), at: doc.pageCount) }
        let file = root.appendingPathComponent(name); try XCTUnwrap(doc.dataRepresentation()).write(to: file); return file
    }
    @MainActor func open(_ file: URL, storage: URL, slot: String = "") throws -> Workspace {
        let w = Workspace(storage: storage, slot: slot); w.bootstrap()
        w.load([file], prepared: .documents([try Data(contentsOf: file)])); return w
    }
    @MainActor func annotate(_ w: Workspace, text: String = "史料批注") -> PDFAnnotation {
        let mark = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 30, height: 20), forType: .text, withProperties: nil)
        mark.contents = text; w.document.page(at: 0)!.addAnnotation(mark); w.recordAnnotationsAdded([mark]); return mark
    }
    @MainActor func settle(_ w: Workspace) async throws {
        let deadline = Date().addingTimeInterval(15)
        while w.busy || w.unloadWorker != nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(w.busy); XCTAssertNil(w.unloadWorker)
    }
    @MainActor func testBookmarksAndClearedBibliographySurviveOriginalPDFClose() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.bookmarkName = "重要史料"; w.addBookmark(); w.bibliography = Bibliography(); w.edited(pdfChanged: false)
        XCTAssertTrue(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.closeDocument())
        let reopened = try open(file, storage: root)
        XCTAssertEqual(reopened.bookmarks.map(\.label), ["重要史料"]); XCTAssertEqual(reopened.bibliography, Bibliography())
    }
    @MainActor func testOCRSourcesRegionsAndSignatureRecordsSurviveClose() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root), original = try w.pdfData()
        w.updateMeta(0) { $0.ocrOriginal = original; $0.ocrRegions = [RecognizedLine(text: "示例史料", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5))] }
        w.edited(pdfChanged: false); XCTAssertTrue(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.closeDocument())
        let reopened = try open(file, storage: root)
        XCTAssertEqual(reopened.meta(0).ocrOriginal, original); XCTAssertEqual(reopened.meta(0).ocrRegions?.first?.text, "示例史料")
    }
    @MainActor func testCompanionMismatchKeepsOldRecordsAndDoesNotApplyWrongPages() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.bookmarkName = "旧页面"; w.addBookmark(); XCTAssertTrue(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.closeDocument())
        let companion = ReadingDocumentStore.location(file, storage: root), before = try Data(contentsOf: companion)
        _ = try pdf(root, pages: 1)
        let reopened = try open(file, storage: root)
        XCTAssertTrue(reopened.bookmarks.isEmpty); XCTAssertTrue(reopened.recoveryStatus.contains("原 PDF 已有变化"))
        XCTAssertEqual(try Data(contentsOf: companion), before)
    }
    @MainActor func testDamagedCompanionRemainsOnDisk() throws {
        let root = try root(), file = try pdf(root), target = ReadingDocumentStore.location(file, storage: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("损坏的阅读记录".utf8); try bad.write(to: target)
        let w = try open(file, storage: root)
        XCTAssertEqual(w.count, 2); XCTAssertTrue(w.bookmarks.isEmpty); XCTAssertFalse(w.recoveryStatus.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), bad)
    }
    @MainActor func testLegacyHistoryMigratesOnlyTheMatchingSavedPDF() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.bookmarkName = "旧版书签"; w.addBookmark(); XCTAssertTrue(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.closeDocument())
        try FileManager.default.removeItem(at: ReadingDocumentStore.location(file, storage: root))
        let reopened = try open(file, storage: root)
        XCTAssertEqual(reopened.bookmarks.map(\.label), ["旧版书签"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ReadingDocumentStore.location(file, storage: root).path))
    }
    @MainActor func testDeletingBookmarksDoesNotResurrectEarlierMetadata() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.bookmarkName = "待删除"; w.addBookmark(); XCTAssertTrue(w.saveDirectly(askForDestination: false))
        w.bookmarks = []; w.edited(pdfChanged: false); XCTAssertTrue(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.closeDocument())
        XCTAssertTrue(try open(file, storage: root).bookmarks.isEmpty)
    }
    @MainActor func testAnnotatedSavedTabsRespectBudgetWithoutDroppingUndo() async throws {
        let root = try root(), store = WorkspaceStore(storage: root); store.bootstrap(); store.maxLoadedTabs = 2
        var ids: [UUID] = []
        for i in 0..<6 {
            let file = try pdf(root, name: "book-\(i).pdf")
            let w = i == 0 ? try XCTUnwrap(store.activeWorkspace) : store.addWorkspace()
            store.select(w.id); w.load([file], prepared: .documents([try Data(contentsOf: file)]))
            _ = annotate(w); XCTAssertTrue(w.saveDirectly(askForDestination: false)); ids.append(w.id); store.loadedTabsChanged()
        }
        for w in store.tabs.compactMap(\.workspace) { try await settle(w) }
        store.loadedTabsChanged()
        for w in store.tabs.compactMap(\.workspace) { try await settle(w) }
        XCTAssertTrue(store.tabs.compactMap(\.workspace).filter { $0.count > 0 }.count <= 2)
        store.select(ids[0]); let first = try XCTUnwrap(store.activeWorkspace); try await settle(first)
        XCTAssertEqual(first.count, 2); XCTAssertTrue(first.canUndo); XCTAssertEqual(first.currentAnnotations.first?.contents, "史料批注")
        for _ in 0..<3 {
            autoreleasepool { first.undo(); XCTAssertTrue(first.currentAnnotations.isEmpty) }
            autoreleasepool { first.redo(); XCTAssertEqual(first.currentAnnotations.first?.contents, "史料批注") }
        }
    }
    @MainActor func testSpillRestoresSnapshotUndoAndRedoAndPrivateData() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.bookmarkName = "留存"; w.addBookmark(); w.rotate(); w.undo()
        w.updateMeta(0) { $0.ocrRegions = [RecognizedLine(text: "校对", box: .zero)] }
        w.edited(pdfChanged: false); XCTAssertTrue(w.saveDirectly(askForDestination: false))
        let undoCount = w.history.count, redoCount = w.future.count
        w.unload(); try await settle(w); XCTAssertEqual(w.count, 0); XCTAssertTrue(w.needsLoad)
        w.ensureLoaded(); try await settle(w)
        XCTAssertEqual(w.bookmarks.map(\.label), ["留存"]); XCTAssertEqual(w.ocrRegions[0]?.first?.text, "校对")
        XCTAssertEqual(w.history.count, undoCount); XCTAssertEqual(w.future.count, redoCount)
        w.redo(); XCTAssertEqual(w.document.page(at: 0)?.rotation, 90)
    }
    @MainActor func testExternalEditDuringSpillRestoresProtectedSession() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        _ = annotate(w); XCTAssertTrue(w.saveDirectly(askForDestination: false)); w.unload(); try await settle(w)
        _ = try pdf(root, pages: 1); let external = try Data(contentsOf: file)
        w.ensureLoaded(); try await settle(w)
        XCTAssertEqual(w.count, 2); XCTAssertTrue(w.saveConflict); XCTAssertTrue(w.dirty); XCTAssertTrue(w.canUndo)
        XCTAssertFalse(w.saveDirectly(askForDestination: false)); XCTAssertEqual(try Data(contentsOf: file), external)
    }
    @MainActor func testDirtyDrawingBusyAndPlacingTabsAreNotSpilled() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.dirty = true; XCTAssertFalse(w.canUnload); w.dirty = false
        w.busy = true; XCTAssertFalse(w.canUnload); w.busy = false
        w.drawingInProgress = true; XCTAssertFalse(w.canUnload); w.unload(); XCTAssertEqual(w.count, 2)
    }
    func testRasterAndFlattenExportKeepConcurrentExternalEditAndGeneratedCopy() throws {
        for mode in [PDFExportMode.raster, .flatten] {
            let root = try root(), input = try pdf(root), output = try pdf(root, name: "output.pdf"), external = try Data(contentsOf: pdf(root, name: "external.pdf", pages: 3))
            var options = ExportOptions(); options.pdfMode = mode; options.dpi = 72
            let spec = JobSpec(operation: .configured, source: try Data(contentsOf: input), pages: [0], destination: output, revision: UUID(), exportOptions: options)
            var copy: URL?
            do { _ = try BackgroundJobs.run(spec) { _ in try? external.write(to: output, options: .atomic) } }
            catch let conflict as ExportOutputConflict { copy = conflict.copy }
            XCTAssertEqual(try Data(contentsOf: output), external)
            XCTAssertEqual(PDFDocument(url: try XCTUnwrap(copy))?.pageCount, 1)
        }
    }
    func testPreserveAndOptimizedHonorCapturedDestinationBaseline() throws {
        for mode in [PDFExportMode.preserve, .optimized] {
            let root = try root(), input = try pdf(root), output = try pdf(root, name: "output.pdf"), expected = try FileBaseline.capture(output)
            let external = try Data(contentsOf: pdf(root, name: "external.pdf", pages: 3)); try external.write(to: output, options: .atomic)
            var options = ExportOptions(); options.pdfMode = mode
            let spec = JobSpec(operation: .configured, source: try Data(contentsOf: input), pages: [0], destination: output, revision: UUID(), exportOptions: options, outputBaseline: expected)
            XCTAssertThrowsError(try BackgroundJobs.run(spec) { _ in })
            XCTAssertEqual(try Data(contentsOf: output), external)
        }
    }
    func testNewlyCreatedDestinationIsNotOverwrittenAfterSelection() throws {
        let root = try root(), input = try pdf(root), output = root.appendingPathComponent("new.pdf"), expected = try FileBaseline.capture(output)
        let other = Data("其他软件的新文件".utf8); try other.write(to: output)
        let spec = JobSpec(operation: .configured, source: try Data(contentsOf: input), pages: [0], destination: output, revision: UUID(), exportOptions: ExportOptions(), outputBaseline: expected)
        XCTAssertThrowsError(try BackgroundJobs.run(spec) { _ in }); XCTAssertEqual(try Data(contentsOf: output), other)
    }
    func testSourceAliasesAreRejectedForExportAndCompression() throws {
        let root = try root(), input = try pdf(root), alias = root.appendingPathComponent("alias.pdf"), hard = root.appendingPathComponent("hard.pdf"), bytes = try Data(contentsOf: input)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input); try FileManager.default.linkItem(at: input, to: hard)
        for target in [input, alias, hard] {
            XCTAssertTrue(DocumentTaskOutput.sameFile(input, target))
            for operation in [JobOperation.configured, .compress] {
                let spec = JobSpec(operation: operation, source: bytes, pages: [0], destination: target, revision: UUID(), exportOptions: ExportOptions(), protectedSource: input)
                XCTAssertThrowsError(try BackgroundJobs.run(spec) { _ in })
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }
    func testCompressionPreservesConcurrentExternalChanges() throws {
        let root = try root(), output = try pdf(root, name: "compressed.pdf")
        let source = try CompressTests().makeScan().data
        let external = try Data(contentsOf: pdf(root, name: "external.pdf", pages: 3))
        let spec = JobSpec(operation: .compress, source: source, pages: [0, 1], destination: output, revision: UUID())
        var copy: URL?
        do { _ = try BackgroundJobs.run(spec) { _ in try? external.write(to: output, options: .atomic) } }
        catch let conflict as ExportOutputConflict { copy = conflict.copy }
        XCTAssertEqual(try Data(contentsOf: output), external)
        XCTAssertNotNil(copy); XCTAssertEqual(PDFDocument(url: try XCTUnwrap(copy))?.pageCount, 2)
    }
    func testRetargetedAliasCannotOverwriteProtectedSourceAtCommit() throws {
        let root = try root(), input = try pdf(root), other = root.appendingPathComponent("other.pdf"), alias = root.appendingPathComponent("alias.pdf")
        let bytes = try Data(contentsOf: input); try bytes.write(to: other)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        let expected = try FileBaseline.capture(alias)
        XCTAssertThrowsError(try DocumentTaskOutput.write(to: alias, expected: expected, protectedSource: input) { staging in
            try bytes.write(to: staging)
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        })
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }
    @MainActor func testRelinkingAnIdenticalBookKeepsItsReadingMetadata() throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.bookmarkName = "随书移动"; w.addBookmark(); XCTAssertTrue(w.saveDirectly(askForDestination: false)); XCTAssertTrue(w.closeDocument())
        let moved = root.appendingPathComponent("moved.pdf"); try FileManager.default.moveItem(at: file, to: moved)
        let library = BookLibrary(storage: root)
        try library.relink(path: file.path, to: moved, defaults: UserDefaults(suiteName: "KongFolio.Relink038." + UUID().uuidString)!)
        XCTAssertEqual(try open(moved, storage: root).bookmarks.map(\.label), ["随书移动"])
    }
    @MainActor func testBackgroundSavePreservesPrivateMetadataAndUndo() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        _ = annotate(w); w.bookmarkName = "异步书签"; w.addBookmark()
        let awaited6 = await w.saveInBackground(); XCTAssertTrue(awaited6); XCTAssertFalse(w.dirty); XCTAssertTrue(w.canUndo)
        XCTAssertTrue(w.closeDocument()); let reopened = try open(file, storage: root)
        XCTAssertEqual(reopened.bookmarks.map(\.label), ["异步书签"]); XCTAssertEqual(reopened.currentAnnotations.first?.contents, "史料批注")
    }
    final class Gate: @unchecked Sendable {
        let lock = NSLock(), release = DispatchSemaphore(value: 0)
        private var _started = false
        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        func wait() { lock.lock(); _started = true; lock.unlock(); _ = release.wait(timeout: .now() + 10) }
    }
    @MainActor func testSlowDiskDoesNotBlockMainActorOrMarkNewerEditsClean() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root), gate = Gate()
        w.rotate(); w.savePreparation = { gate.wait() }
        let saving = Task { await w.saveInBackground() }
        let deadline = Date().addingTimeInterval(5)
        while !gate.started, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(gate.started); XCTAssertTrue(w.saving)
        // Main actor is free to run while disk coordination is stalled.
        let before = Date(); w.rotate(); XCTAssertTrue(Date().timeIntervalSince(before) < 0.2)
        gate.release.signal(); let awaited5 = await saving.value; XCTAssertTrue(awaited5)
        XCTAssertEqual(PDFDocument(url: file)?.page(at: 0)?.rotation, 90); XCTAssertEqual(w.document.page(at: 0)?.rotation, 180); XCTAssertTrue(w.dirty)
        w.savePreparation = nil; let awaited4 = await w.finishPendingSave(); XCTAssertTrue(awaited4)
        XCTAssertFalse(w.dirty); XCTAssertEqual(PDFDocument(url: file)?.page(at: 0)?.rotation, 180)
    }
    @MainActor func testExternalModificationDuringBackgroundSaveNeverOverwrites() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root), gate = Gate()
        w.rotate(); w.savePreparation = { gate.wait() }; let saving = Task { await w.saveInBackground() }
        let deadline = Date().addingTimeInterval(5)
        while !gate.started, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let external = try Data(contentsOf: pdf(root, name: "external.pdf", pages: 3)); try external.write(to: file, options: .atomic)
        gate.release.signal(); let awaited3 = await saving.value; XCTAssertFalse(awaited3); XCTAssertTrue(w.dirty); XCTAssertTrue(w.saveConflict)
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    @MainActor func testCloseFlushesTheLastEditsWhileAnOlderSaveRuns() async throws {
        let root = try root(), file = try pdf(root), w = try open(file, storage: root)
        w.rotate(); let first = Task { await w.saveInBackground() }; await Task.yield(); w.rotate()
        let awaited2 = await first.value; XCTAssertTrue(awaited2); let awaited1 = await w.finishPendingSave(); XCTAssertTrue(awaited1); XCTAssertFalse(w.dirty)
        XCTAssertEqual(PDFDocument(url: file)?.page(at: 0)?.rotation, 180)
    }
    @MainActor func testReflectionTypingIsCoalescedAndFinalTextFlushed() async throws {
        let root = try root(), file = try pdf(root), library = BookLibrary(storage: root); try library.add([file])
        let id = try XCTUnwrap(library.books.first?.id)
        for i in 1...100 { try library.scheduleReflection(id, text: "心得第\(i)次") }
        XCTAssertEqual(library.reflectionWriteCount, 0)
        try await library.flushReflections(); XCTAssertEqual(library.reflectionWriteCount, 1)
        XCTAssertEqual(BookLibrary(storage: root).books.first?.reflection, "心得第100次")
    }
    @MainActor func testLaterCatalogChangesDoNotRestoreOldReflection() async throws {
        let root = try root(), file = try pdf(root), library = BookLibrary(storage: root); try library.add([file])
        var book = try XCTUnwrap(library.books.first); try library.scheduleReflection(book.id, text: "最新心得")
        book = try XCTUnwrap(library.books.first); book.favorite = true; try library.update(book)
        try await library.flushReflections()
        let reopened = BookLibrary(storage: root); XCTAssertTrue(reopened.books.first?.favorite == true); XCTAssertEqual(reopened.books.first?.reflection, "最新心得")
    }
    @MainActor func testClosedTextDocumentCancelsPreviewAndReleasesCachedPDF() async throws {
        let note = MarkdownNote(text: "# 开始", storage: try root())
        note.releaseEditorResources(); try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(note.preview); note.text = "关闭后变化"; try await Task.sleep(nanoseconds: 500_000_000); XCTAssertNil(note.preview)
    }
    func testBackgroundTextPreviewSupportsAllThreeFormats() async throws {
        for (format, text) in [(TextDocumentFormat.markdown, "# 中国近现代史\n\n阅读笔记"), (.plain, "纯文本\n第二行"), (.html, "<h1>史料</h1><p>正文</p>")] {
            let data = try await TextPreviewRenderer.render(text, format: format, base: nil, options: TextLayoutOptions())
            XCTAssertTrue(PDFDocument(data: try XCTUnwrap(data))?.pageCount ?? 0 > 0)
        }
    }
}
