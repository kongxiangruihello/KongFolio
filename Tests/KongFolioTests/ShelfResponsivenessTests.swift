import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class ShelfResponsivenessTests: XCTestCase {
    func testHistoryCanonicalizesEachDistinctPathOnlyOnce() {
        let paths = (0..<1200).map { "/book\($0).pdf" }; var calls = 0
        let cache = BookLibrary.historyIdentities(paths+paths) { path in calls += 1; return path }
        XCTAssertEqual(calls,1200); XCTAssertEqual(cache.count,1200)
    }
    func testCloudCoverPolicyDoesNotDownloadMissingOriginals() {
        XCTAssertFalse(LibraryCoverLoader.mayReadCover(ubiquitous:true,status:.notDownloaded,dataless:false))
        XCTAssertFalse(LibraryCoverLoader.mayReadCover(ubiquitous:true,status:nil,dataless:false))
        XCTAssertFalse(LibraryCoverLoader.mayReadCover(ubiquitous:false,status:nil,dataless:true))
        XCTAssertTrue(LibraryCoverLoader.mayReadCover(ubiquitous:true,status:.current,dataless:false))
        XCTAssertTrue(LibraryCoverLoader.mayReadCover(ubiquitous:false,status:nil,dataless:false))
    }
    func testCoverCacheDoesNotReparseTheSameUnchangedPDF() async throws {
        let root = try Release027Tests().folder(), file = try Release038Tests().pdf(root), loader = LibraryCoverLoader()
        let first = try await loader.load(file), second = try await loader.load(file)
        XCTAssertNotNil(first); XCTAssertEqual(first,second); let count = await loader.renderCount; XCTAssertEqual(count,1)
        var bytes = try Data(contentsOf:file); bytes.append(10); try bytes.write(to:file)
        _ = try await loader.load(file); let changed = await loader.renderCount; XCTAssertEqual(changed,2)
    }
    func testCancelledCoverRequestDoesNotRender() async throws {
        let root = try Release027Tests().folder(), file = try Release038Tests().pdf(root), loader = LibraryCoverLoader()
        let task = Task { try Task.checkCancellation(); return try await loader.load(file) }; task.cancel()
        do { _ = try await task.value; XCTAssertTrue(false) } catch {}
        let count = await loader.renderCount; XCTAssertEqual(count,0)
    }
    @MainActor func testRepeatedOpenReusesExistingBookWithoutLosingItsEdits() async throws {
        let root = try Release027Tests().folder(), file = try Release038Tests().pdf(root), store = WorkspaceStore(storage:root); store.bootstrap()
        let w = store.activeWorkspace!; w.load([file],prepared:.documents([try Data(contentsOf:file)])); _ = Release038Tests().annotate(w,text:"保留未保存标注")
        store.openEach([file,file]); XCTAssertEqual(store.tabs.count,1); XCTAssertTrue(store.activeWorkspace === w); XCTAssertTrue(w.dirty); XCTAssertEqual(w.currentAnnotations.first?.contents,"保留未保存标注")
    }
    @MainActor func testThousandRecordShelfRefreshKeepsMainActorResponsive() async throws {
        let root = try Release027Tests().folder(), folder = root.appendingPathComponent("Library"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let suite = "KongFolio.ShelfBenchmark."+UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var actual = false
        if let fixture = ProcessInfo.processInfo.environment["KONGFOLIO_LIBRARY_FIXTURE"] {
            let input = URL(fileURLWithPath:fixture)
            try FileManager.default.copyItem(at:input.appendingPathComponent("catalog.json"),to:folder.appendingPathComponent("catalog.json"))
            let data = try Data(contentsOf:input.appendingPathComponent("progress.plist")), progress = try XCTUnwrap(PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any])
            defaults.setPersistentDomain(progress,forName:suite); actual = true
        } else {
            var catalog = BookLibrary.Catalog(), snapshot:[String:Any] = [:]
            for i in 0..<1083 {
                let path = "/KongFolio-Synthetic-\(i).pdf"; catalog.books.append(LibraryBook(path:path,title:"书籍\(i)"))
                snapshot["KongFolio.progress."+path] = ["last":i%4,"pages":4,"date":1_800_000_000.0,"visited":"0-1"]
            }
            try JSONEncoder().encode(catalog).write(to:folder.appendingPathComponent("catalog.json")); defaults.setPersistentDomain(snapshot,forName:suite)
        }
        let library = BookLibrary(storage:root), initial = library.books.count
        var beats = 0, longestGap = 0.0, previous = Date()
        let ticker = Task { @MainActor in while !Task.isCancelled { let now = Date(); longestGap = max(longestGap,now.timeIntervalSince(previous)); previous = now; beats += 1; do { try await Task.sleep(nanoseconds:2_000_000) } catch { return } } }
        defer { ticker.cancel() }
        await Task.yield(); let started = Date(), progress = try await library.refreshHistory(defaults:defaults), elapsed = Date().timeIntervalSince(started)
        await Task.yield(); XCTAssertTrue(library.books.count >= initial); XCTAssertEqual(progress.count,library.books.count); XCTAssertTrue(beats > 1); XCTAssertTrue(longestGap < 1.0,"Book shelf refresh must yield to the main actor")
        let report:[String:Any] = ["actualLibrarySnapshot":actual,"books":library.books.count,"elapsedSeconds":elapsed,"mainActorBeats":beats,"longestMainActorGapSeconds":longestGap,"originalsOpenedForHistory":0]
        if let destination = ProcessInfo.processInfo.environment["KONGFOLIO_SHELF_REPORT"] { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination)) }
        print("SHELF_STRESS books=\(library.books.count) elapsedSeconds=\(elapsed) mainActorBeats=\(beats) longestGap=\(longestGap) actual=\(actual)")
    }
    @MainActor func testHistoryRefreshPreservesMetadataChangedWhileItWasPreparing() async throws {
        let root = try Release027Tests().folder(), file = try Release038Tests().pdf(root), library = BookLibrary(storage:root), defaults = UserDefaults(suiteName:"ShelfMerge-"+UUID().uuidString)!
        try library.add([file]); ReadingProgress(last:1,date:Date(),pages:4).save(path:file.path,defaults:defaults)
        let job = Task { try await library.refreshHistory(defaults:defaults) }
        var book = library.books[0]; book.favorite = true; book.category = "已修改分类"; try library.update(book)
        _ = try await job.value; XCTAssertTrue(library.books[0].favorite); XCTAssertEqual(library.books[0].category,"已修改分类")
    }
}
