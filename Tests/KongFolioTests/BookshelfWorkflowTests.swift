import XCTest
import PDFKit
@testable import KongFolio

final class BookshelfWorkflowTests: XCTestCase {
    @MainActor func testMultipleTopicsPersistAndRemovalCanBeUndone() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try Release037Tests().pdf(root)
        let library = BookLibrary(storage:root)
        try library.add([file])
        var book = try XCTUnwrap(library.books.first)
        book.category = "近代教育"
        try library.update(book)
        _ = try library.addShelfTopic("万国公报",adding:[book.id])
        XCTAssertEqual(Set(library.books[0].shelfTopics),["近代教育","万国公报"])
        _ = try library.updateShelfTopic("万国公报",replacement:"史料")
        XCTAssertEqual(Set(library.books[0].shelfTopics),["近代教育","史料"])
        try library.undoShelfEdit()
        XCTAssertEqual(Set(BookLibrary(storage:root).books[0].shelfTopics),["近代教育","万国公报"])
        try library.removeBooks([book.id])
        XCTAssertTrue(library.books.isEmpty)
        try library.undoShelfEdit()
        XCTAssertEqual(library.books[0].id,book.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }

    @MainActor func testExactDuplicateIsSkippedAndAnEditedVersionCanBeAdded() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try Release037Tests().pdf(root)
        let duplicate = root.appendingPathComponent("同一内容.pdf")
        try FileManager.default.copyItem(at:file,to:duplicate)
        let library = BookLibrary(storage:root)
        try library.add([file,duplicate])
        XCTAssertEqual(library.books.count,1)
        var bytes = try Data(contentsOf:file)
        bytes.append(10)
        try bytes.write(to:file)
        try library.add([duplicate])
        XCTAssertEqual(library.books.count,2)
    }

    @MainActor func testRelinkVerifiesMovedCopyAndPreservesDockTarget() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try Release037Tests().pdf(root)
        let library = BookLibrary(storage:root)
        try library.add([file])
        let book = try XCTUnwrap(library.books.first)
        let destination = root.appendingPathComponent("已移动.pdf")
        try FileManager.default.moveItem(at:file,to:destination)
        let review = try ShelfRelinkReview.inspect(book,url:destination)
        XCTAssertTrue(review.verified)
        let defaults = Release037Tests().suite()
        let shortcut = ReadingShortcut(path:book.path,title:book.title,mode:.fixed,position:ViewPosition(selection:1),bookmark:book.bookmark)
        try library.relink(path:book.path,to:destination,defaults:defaults,validated:true,verifiedDigest:review.digest)
        XCTAssertEqual(library.resolve(shortcut).position.selection,1)
        XCTAssertEqual(try library.resolve(shortcut).resolvedURL().resolvingSymlinksInPath().path,destination.resolvingSymlinksInPath().path)
    }

    func testContinueReadingExcludesMerelyOpenedAndFinishedBooks() {
        let idle = LibraryBook(path:"/刚打开.pdf",title:"刚打开")
        let active = LibraryBook(path:"/在读.pdf",title:"在读",shelfAuthor:"林乐知",shelfPeriodical:"万国公报",shelfYear:"1907")
        let finished = LibraryBook(path:"/读完.pdf",title:"读完",readingStatus:.finished)
        let progress = [idle.path:ReadingProgress(date:Date()),active.path:ReadingProgress(visited:[2],last:2,date:Date(),pages:9),
                        finished.path:ReadingProgress(visited:[0],date:Date(),pages:1)]
        XCTAssertEqual(ShelfBrowse.recent([idle,active,finished],progress:progress).map(\.id),[active.id])
        XCTAssertEqual(active.matchingShelfField("林乐知"),"作者")
        XCTAssertEqual(active.matchingShelfField("万国公报"),"刊名")
        XCTAssertEqual(active.matchingShelfField("1907"),"年代")
    }

    @MainActor func testReferencePageDoesNotOverwriteResumePosition() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let file = try Release037Tests().pdf(root), defaults = Release037Tests().suite()
        let store = WorkspaceStore(storage:root,readingDefaults:defaults)
        store.bootstrap()
        let workspace = try XCTUnwrap(store.activeWorkspace)
        workspace.load([file],prepared:.documents([try Data(contentsOf:file)]))
        workspace.selectPage(1)
        workspace.readingPoint = CGPoint(x:20,y:40)
        workspace.saveReadingRecord(capture:false,markVisited:true)
        let book = LibraryBook(path:file.path,title:"书")
        XCTAssertTrue(store.reveal(SourceRef(path:file.path,fileName:"书.pdf",page:2),beside:false))
        XCTAssertEqual(workspace.selection,2)
        workspace.saveReadingRecord(capture:false,markVisited:true)
        XCTAssertEqual(ReadingProgress.load(path:file.path,defaults:defaults).last,1)
        try store.openLibraryBook(book)
        XCTAssertEqual(workspace.selection,1)
        XCTAssertEqual(workspace.readingPoint,CGPoint(x:20,y:40))
        workspace.selectPage(3)
        XCTAssertEqual(ReadingProgress.load(path:file.path,defaults:defaults).last,3)
    }
}
