import XCTest
import PDFKit
@testable import KongFolio

final class ReadingMemoryTests: XCTestCase {
    @MainActor func testOriginalPDFMetadataDoesNotDisableLoadedTabLimit() throws {
        let root = try Release027Tests().folder()
        let store = WorkspaceStore(storage: root, readingDefaults: UserDefaults(suiteName: "KongFolio.Memory." + UUID().uuidString)!)
        store.bootstrap(); store.maxLoadedTabs = 2
        for index in 0..<6 {
            let doc = PDFDocument(); doc.insert(PDFPage(), at: 0)
            doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "原件书名", PDFDocumentAttribute.authorAttribute: "原件作者"]
            let file = root.appendingPathComponent("book-\(index).pdf"); try XCTUnwrap(doc.dataRepresentation()).write(to: file)
            let workspace = index == 0 ? try XCTUnwrap(store.activeWorkspace) : store.addWorkspace()
            workspace.document = doc; workspace.sourceURL = file; workspace.bibliography = ReadingServices.bibliography(from: doc)
            XCTAssertFalse(workspace.hasPrivateReadingData); XCTAssertTrue(workspace.canUnload)
            store.loadedTabsChanged()
        }
        XCTAssertEqual(store.tabs.compactMap(\.workspace).filter { $0.count > 0 }.count, 2)
        let unloaded = store.tabs.compactMap(\.workspace).filter(\.needsLoad)
        XCTAssertEqual(unloaded.count, 4)
        XCTAssertTrue(unloaded.allSatisfy { $0.sourceURL != nil && $0.count == 0 })
    }
    @MainActor func testEditedOrClearedBibliographyRemainsProtected() throws {
        let workspace = Workspace(storage: try Release027Tests().folder())
        workspace.document.insert(PDFPage(), at: 0)
        workspace.document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "原件书名"]
        workspace.bibliography = ReadingServices.bibliography(from: workspace.document)
        XCTAssertFalse(workspace.hasPrivateReadingData)
        workspace.bibliography.title = "我的修订书名"
        XCTAssertTrue(workspace.hasPrivateReadingData); XCTAssertFalse(workspace.canUnload)
        workspace.bibliography = Bibliography()
        XCTAssertTrue(workspace.hasPrivateReadingData)
        workspace.bibliography = ReadingServices.bibliography(from: workspace.document)
        workspace.bookmarks = [PageBookmark(page: 0, label: "我的书签")]
        XCTAssertTrue(workspace.hasPrivateReadingData)
    }
}
