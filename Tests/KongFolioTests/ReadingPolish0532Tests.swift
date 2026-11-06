import XCTest
import SwiftUI
import PDFKit
@testable import KongFolio

@MainActor final class ReadingPolish0532Tests: XCTestCase {
    func testHighlightMarksEveryOccurrenceWithoutChangingTextOrEmoji() {
        let text="📖 袁世凯与袁世凯。"
        let ranges=SearchResultHighlight.ranges(text,query:"袁世凯")
        XCTAssertEqual(ranges.count,2)
        XCTAssertEqual(ranges.map{(text as NSString).substring(with:$0)},["袁世凯","袁世凯"])
        let marked=SearchResultHighlight.text(text,query:"袁世凯")
        XCTAssertEqual(String(marked.characters),text)
        XCTAssertEqual(marked.runs.filter{$0.backgroundColor == .yellow}.count,2)
        XCTAssertTrue(marked.runs.filter{$0.backgroundColor == .yellow}.allSatisfy{$0.foregroundColor == .black})
    }
    func testHighlightUsesPDFTraditionalAndWhitespaceFolding() {
        let text="袁\n世凱，ABC及ＡＢＣ"
        XCTAssertEqual(SearchResultHighlight.ranges(text,query:"袁世凯"),[NSRange(location:0,length:4)])
        XCTAssertEqual(SearchResultHighlight.ranges(text,query:"abc").count,2)
    }
    func testEmptyUnmatchedAndExcessiveKeywordsLeaveTextUnchanged() {
        for query in [""," \n","不存在",String(repeating:"词",count:501)] {
            let value=SearchResultHighlight.text("普通文字📖",query:query)
            XCTAssertEqual(String(value.characters),"普通文字📖")
            XCTAssertTrue(value.runs.allSatisfy{$0.backgroundColor == nil})
        }
    }
    func testPDFResultsRetainExecutedQueryForHighlighting() throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let url=try PDFTextSnapshot053Tests().fixture(root)
        let hits=try ReadingServices.search(Data(contentsOf:url),query:"FindPage2Only")
        XCTAssertEqual(hits.count,1);XCTAssertEqual(hits.first?.query,"FindPage2Only")
        XCTAssertEqual(SearchResultHighlight.ranges(hits[0].snippet,query:hits[0].query!).count,1)
    }
    func testPinsDoNotOverrideUserOrderWhenWindowFitsAllTools() {
        var p=ReaderToolbarProfile();p.pinned=["library","newFile"]
        p.move(.newFile,by:1);p.move(.library,by:-1)
        XCTAssertEqual(p.visible(width:2000),p.actions.filter{p.pinned.contains($0.rawValue)})
        XCTAssertEqual(p.visible(width:2000).first,.newFile)
    }
    func testNarrowWindowPrioritizesPinsButPreservesTheirUserOrder() {
        var p=ReaderToolbarProfile();p.pinned=["library","books","signature"]
        for width in stride(from:320.0,through:1800,by:20) {
            let visible=p.visible(width:width),hidden=p.hidden(width:width)
            XCTAssertEqual(Set(visible+hidden),Set(p.actions))
            XCTAssertEqual(visible,p.actions.filter{visible.contains($0)})
            if visible.count>=3 { XCTAssertTrue([FileToolbarAction.library,.books,.signature].allSatisfy{visible.contains($0)}) }
        }
        XCTAssertEqual(p.visible(width:320),[.library,.books,.signature])
    }
    func testToolbarOrderAndPinsSurviveDecodingAndReset() throws {
        let name=UUID().uuidString,d=try XCTUnwrap(UserDefaults(suiteName:name));defer{d.removePersistentDomain(forName:name)}
        var p=ReaderToolbarProfile();p.move(.newFile,by:1);p.pinned=["signature"];p.save(d)
        let decoded=ReaderToolbarProfile.decode(d.data(forKey:ReaderToolbarProfile.key))
        XCTAssertEqual(decoded,p);XCTAssertEqual(decoded.visible(width:2000),[.signature])
        XCTAssertEqual(ReaderToolbarProfile.decode(Data("invalid".utf8)),ReaderToolbarProfile())
        ReaderToolbarProfile().save(d);XCTAssertEqual(ReaderToolbarProfile.load(d),ReaderToolbarProfile())
    }
    func testCurrentPDFShelfTargetFollowsFocusedSavedPane() throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=WorkspaceStore(storage:root);store.bootstrap();XCTAssertNil(store.currentPDFForShelf)
        let first=try XCTUnwrap(store.activeWorkspace),second=store.addWorkspace()
        let a=try Release046Tests().pdf(root,name:"第一本.pdf"),b=try Release046Tests().pdf(root,name:"第二本.pdf")
        first.load([a],prepared:.documents([try Data(contentsOf:a)]));second.load([b],prepared:.documents([try Data(contentsOf:b)]))
        store.select(first.id);XCTAssertEqual(store.currentPDFForShelf,a)
        first.splitPartner=second;store.focus(second);XCTAssertEqual(store.currentPDFForShelf,b)
        second.sourceURL=nil;XCTAssertNil(store.currentPDFForShelf)
        _=store.newNote();XCTAssertNil(store.currentPDFForShelf)
    }
    func testAddingCurrentPDFIsManualDeduplicatedAndRetainsShelfMetadata() async throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=WorkspaceStore(storage:root);store.bootstrap();let w=try XCTUnwrap(store.activeWorkspace)
        let url=try Release046Tests().pdf(root);let original=try Data(contentsOf:url)
        w.load([url],prepared:.documents([original]));XCTAssertTrue(store.library.books.isEmpty)
        w.selection=1;w.saveReadingRecord();let target=try XCTUnwrap(store.currentPDFForShelf)
        try await store.library.addInBackground([target]);var book=try XCTUnwrap(store.library.books.first)
        book.title="我的书名";book.reflection="已有心得";book.favorite=true;try store.library.update(book)
        try await store.library.addInBackground([target]);XCTAssertEqual(store.library.books,[book])
        XCTAssertEqual(BookLibrary(storage:root).books,[book])
        XCTAssertEqual(ReadingProgress.load(path:url.path,defaults:store.readingDefaults).last,1)
        XCTAssertEqual(try Data(contentsOf:url),original)
    }
}
