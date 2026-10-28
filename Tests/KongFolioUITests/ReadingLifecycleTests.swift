import XCTest
import SwiftUI
import PDFKit
import AppKit
import Darwin
@testable import KongFolio

final class ReadingLifecycleTests: XCTestCase {
    final class WeakDocument { weak var value: PDFDocument?; init(_ value: PDFDocument) { self.value = value } }
    @MainActor func settle(_ host: NSView, milliseconds: UInt64 = 40) async throws {
        autoreleasepool { host.layoutSubtreeIfNeeded() }
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        autoreleasepool { host.layoutSubtreeIfNeeded() }
    }
    func residentMB() -> Double {
        var value = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(value.resident_size) / 1048576 : 0
    }
    func inputs(_ directory: URL) throws -> [URL] {
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_STRESS_INPUT"] {
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }.sorted { $0.path < $1.path }
            guard urls.count >= 20 else { throw NSError(domain: "stress", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stress fixture needs 20 PDFs"]) }
            return Array(urls.prefix(20))
        }
        let context = CGContext(data: nil, width: 800, height: 1100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 1100))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 40, to: 1050, by: 18) { for x in stride(from: 30, to: 750, by: 22) { context.fill(CGRect(x: x, y: y, width: 8 + x % 7, height: 3 + y % 9)) } }
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 600, height: 825))
        let doc = PDFDocument(); doc.insert(PDFPage(image: image)!, at: 0); doc.insert(PDFPage(image: image)!, at: 1)
        let data = try XCTUnwrap(doc.dataRepresentation())
        return try (1...20).map { number in let file = directory.appendingPathComponent("book-\(number).pdf"); try data.write(to: file); return file }
    }
    @MainActor func readAndClose(store: WorkspaceStore, id: UUID, host: NSView) async throws -> WeakDocument {
        autoreleasepool { store.select(id) }
        let deadline = Date().addingTimeInterval(20)
        while store.activeWorkspace?.busy == true, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let workspace = try XCTUnwrap(store.activeWorkspace)
        XCTAssertFalse(workspace.busy); XCTAssertNil(workspace.error); XCTAssertTrue(workspace.count > 0)
        try await settle(host)
        let nativeView = try XCTUnwrap(workspace.pdfView)
        let weak = WeakDocument(workspace.document)
        if workspace.count > 1 { workspace.selectPage(workspace.count - 1); try await settle(host) }
        autoreleasepool { store.close(id) }
        XCTAssertNil(nativeView.document, "Closing must immediately detach the native preview")
        try await settle(host)
        return weak
    }
    @MainActor func testThreeRoundsOfTwentyScansReleaseDocumentsAndStayResponsive() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kf-stress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try inputs(root), storage = root.appendingPathComponent("storage")
        let original = try files.map { OCRPageCache.digest(try Data(contentsOf: $0)) }
        let store = WorkspaceStore(storage: storage, readingDefaults: UserDefaults(suiteName: "KongFolio.Stress." + UUID().uuidString)!)
        store.bootstrap()
        let host = NSHostingView(rootView: AnyView(RootView(store: store))); host.frame = NSRect(x: 0, y: 0, width: 1280, height: 850)
        try await settle(host, milliseconds: 100)
        var documents: [WeakDocument] = [], memory: [Double] = [], largestStep = 0.0
        let rounds = max(3, min(10, Int(ProcessInfo.processInfo.environment["KONGFOLIO_STRESS_ROUNDS"] ?? "3") ?? 3))
        for round in 1...rounds {
            store.openEach(files)
            let ids = store.tabs.map(\.id)
            XCTAssertEqual(ids.count, 20)
            for id in ids {
                let start = Date()
                documents.append(try await readAndClose(store: store, id: id, host: host))
                largestStep = max(largestStep, Date().timeIntervalSince(start))
            }
            // PDFKit may finish an in-flight system text analysis after the tab disappears.
            // Bound the grace period; a view that still owns its document never passes this check.
            let releaseDeadline = Date().addingTimeInterval(20)
            while documents.contains(where: { $0.value != nil }), Date() < releaseDeadline { try await settle(host, milliseconds: 100) }
            try await settle(host, milliseconds: 150)
            let live = documents.filter { $0.value != nil }.count
            memory.append(residentMB())
            print("STRESS round=\(round) opened=20 closed=20 liveClosedDocuments=\(live) residentMB=\(memory.last!) longestStepSeconds=\(largestStep)")
            XCTAssertEqual(store.tabs.count, 1); XCTAssertEqual(store.activeWorkspace?.count, 0)
            XCTAssertEqual(live, 0, "Closed PDF documents must not accumulate between reading rounds")
        }
        XCTAssertLessThan(memory.last! - memory.first!, 256, "Memory must stabilize after warm-up")
        XCTAssertLessThan(largestStep, 20, "Each reading/closing step must complete")
        XCTAssertEqual(try files.map { OCRPageCache.digest(try Data(contentsOf: $0)) }, original)
        host.rootView = AnyView(EmptyView()); try await settle(host)
    }
    @MainActor func testDismantledReadingViewReleasesDocumentWhileViewIsCached() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kf-view-" + UUID().uuidString)
        let workspace = Workspace(storage: root)
        let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); workspace.document = doc
        let host = NSHostingView(rootView: AnyView(PDFCanvas(workspace: workspace)))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let cachedView = try XCTUnwrap(workspace.pdfView)
        XCTAssertTrue(cachedView.document === doc)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(cachedView.document, "A retired PDFView must drop the old PDF even if its native view is cached")
        XCTAssertNil(workspace.pdfView)
    }
    @MainActor func testClosingDocumentDetachesRetainedNativeViewAndAnnotationClipboard() async throws {
        _ = NSApplication.shared
        let workspace = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let doc = PDFDocument(); let page = PDFPage(); doc.insert(page, at: 0)
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 30, height: 20), forType: .text, withProperties: nil)
        page.addAnnotation(annotation); workspace.document = doc; workspace.copiedAnnotations = [annotation]
        let host = NSHostingView(rootView: AnyView(PDFCanvas(workspace: workspace))); host.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await settle(host)
        let view = try XCTUnwrap(workspace.pdfView)
        XCTAssertTrue(workspace.closeDocument())
        XCTAssertNil(view.document); XCTAssertNil(workspace.pdfView)
        XCTAssertTrue(workspace.copiedAnnotations.isEmpty); XCTAssertEqual(workspace.count, 0)
        host.rootView = AnyView(EmptyView()); try await settle(host)
    }
    @MainActor func testReusedCanvasNotificationsFollowTheCurrentWorkspace() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = Workspace(storage: root), second = Workspace(storage: root)
        for workspace in [first, second] { workspace.document.insert(PDFPage(), at: 0); workspace.document.insert(PDFPage(), at: 1) }
        let host = NSHostingView(rootView: AnyView(PDFCanvas(workspace: first))); host.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await settle(host)
        let previous = try XCTUnwrap(first.pdfView)
        host.rootView = AnyView(PDFCanvas(workspace: second)); try await settle(host)
        let current = try XCTUnwrap(second.pdfView)
        XCTAssertNil(first.pdfView)
        current.go(to: second.document.page(at: 1)!)
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: current)
        try await settle(host)
        XCTAssertEqual(second.selection, 1); XCTAssertEqual(first.selection, 0)
        host.rootView = AnyView(EmptyView()); try await settle(host)
        XCTAssertNil(current.document); XCTAssertNil(previous.document); XCTAssertNil(second.pdfView)
    }

}
