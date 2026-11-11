import AppKit
import PDFKit
import XCTest
@testable import KongFolio

final class ReadingExcerptWorkflowTests: XCTestCase {
    private func excerpt(_ quote: String, book: String = "史料甲", page: Int = 0, y: CGFloat = 50) -> ReadingRecord {
        let source = SourceRef(path:"/tmp/"+book+".pdf",fileName:book+".pdf",page:page,
                               rects:[CGRect(x:10,y:y,width:50,height:12)])
        return ReadingRecord(kind:.excerpt,quote:quote,citations:[ReadingCitation(source:source,title:book)])
    }

    @MainActor func testDuplicateReturnsExistingExcerptAndUndoIsScoped() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        let record = excerpt("相同原文")
        XCTAssertTrue(store.saveReadingExcerpt(record))
        XCTAssertEqual(store.readingExcerptFeedback?.recordID,record.id)
        XCTAssertTrue(store.saveReadingExcerpt(excerpt("相同原文",y:51)))
        XCTAssertTrue(store.readingExcerptFeedback?.message.contains("已摘录过") == true)
        XCTAssertEqual(store.journal.state.records.count,1)
        let separate = excerpt("相同原文",y:120)
        XCTAssertTrue(store.saveReadingExcerpt(separate))
        let unrelated = ReadingRecord(kind:.note,note:"其他记录保留")
        store.journal.add(unrelated)
        XCTAssertTrue(store.undoCapturedExcerpt(separate.id))
        XCTAssertEqual(Set(store.journal.state.records.map(\.id)),[record.id,unrelated.id])
        XCTAssertFalse(store.undoCapturedExcerpt(separate.id))
    }

    @MainActor func testAppendKeepsSeparateSourcesAndUndoRestoresPriorExcerpt() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        var initial = excerpt("第一段")
        initial.excerptRemark = "值得复核"
        let second = excerpt("续文",book:"史料乙",page:3)
        XCTAssertTrue(store.saveReadingExcerpt(initial))
        XCTAssertTrue(store.saveReadingExcerpt(second,append:true))
        let merged = try XCTUnwrap(store.journal.record(initial.id))
        XCTAssertEqual(merged.excerptRemark,initial.excerptRemark)
        XCTAssertEqual(merged.textExcerptSegments.map(\.text),["第一段","续文"])
        XCTAssertEqual(merged.textExcerptSegments.map { $0.sources(in:merged).map(\.source.page) },[[0],[3]])
        try await store.journal.flush()
        let reopened = ReadingJournal(storage:root)
        XCTAssertEqual(reopened.record(initial.id)?.excerptSegments,merged.excerptSegments)
        XCTAssertTrue(store.saveReadingExcerpt(excerpt("续文",book:"史料乙",page:3),append:true))
        XCTAssertEqual(store.journal.record(initial.id)?.excerptSegments?.count,2)
        XCTAssertTrue(store.undoCapturedExcerpt(initial.id))
        XCTAssertEqual(store.journal.record(initial.id),initial)
        XCTAssertNil(store.journal.state.lastNotes[second.citations[0].source.path])
    }

    @MainActor func testRemarkIsSearchableAndFollowsExcerptIntoANote() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        var record = excerpt("摘录正文")
        record.excerptRemark = "与前篇说法不同"
        store.journal.add(record)
        XCTAssertTrue(record.matches("前篇说法"))
        XCTAssertTrue(ReadingLibraryItem.record(record).searchText053(.mine).contains("前篇说法"))
        XCTAssertTrue(ReadingLibraryItem.record(record).matchingContext("前篇说法")?.contains("前篇说法") == true)
        XCTAssertEqual(store.prepareReadingNote(linked:record)?.note,record.excerptRemark)
    }

    func testContextReturnsLinesAroundSelectedText() throws {
        let document = try RichTextDocument("Earlier line\nChosen quotation\nFollowing line",format:.plain).pdf()
        let page = try XCTUnwrap(document.page(at:0))
        let source = SourceRef(path:"/tmp/source.pdf",fileName:"source.pdf",page:0,anchor:"Chosen quotation")
        let passage = try XCTUnwrap(ReadingContextLoader.passage(on:page,source:source))
        XCTAssertTrue(passage.before.contains("Earlier line"))
        XCTAssertEqual(passage.selection,"Chosen quotation")
        XCTAssertTrue(passage.after.contains("Following line"))
    }

    @MainActor func testThreeExportFormatsFollowSelectionAndKeepRemarkSegmentsAndDates() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        var first = excerpt("跨页段落甲")
        first.excerptRemark = "需要进一步查证"
        first.appendExcerpt(excerpt("跨页段落乙",book:"史料续篇",page:3))
        let second = excerpt("先导出的选段",book:"另一书",page:2)
        store.journal.add(first)
        store.journal.add(second)
        store.readingRecordSelection.insert(second.id)
        store.readingRecordSelection.insert(first.id)
        XCTAssertEqual(store.readingRecordSelectionOrder,[second.id,first.id])
        let order = store.readingRecordSelectionOrder.map { ReadingLibraryID.record($0).exportOrderKey }
        let items = ReadingExportOrdering.sorted([.record(first),.record(second)],by:.selection,selection:order)
        XCTAssertEqual(items.map(\.id),order)
        let snapshot = ReadingExportSnapshot(title:"资料汇编",records:[first,second],order:items.map(\.id))
        for format in ReadingRecordExport.Format.allCases {
            let file = root.appendingPathComponent("导出."+format.ext)
            try ReadingRecordExport.write(snapshot,format:format,assets:root,to:file,expected:FileBaseline.capture(file))
            let text: String
            switch format {
            case .markdown: text = try String(contentsOf:file,encoding:.utf8)
            case .pdf: text = try XCTUnwrap(PDFDocument(url:file)?.string)
            case .word:
                let parts = try ReadingExportAudit.storedZIP(Data(contentsOf:file))
                text = String(decoding:try XCTUnwrap(parts["word/document.xml"]),as:UTF8.self)
            }
            let normalized = text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
            for phrase in ["跨页段落甲","跨页段落乙","史料续篇","第4页","需要进一步查证","记录时间"] {
                XCTAssertTrue(normalized.contains(phrase),format.rawValue+": "+phrase)
            }
            XCTAssertLessThan(try XCTUnwrap(normalized.range(of:"先导出的选段")).lowerBound,
                              try XCTUnwrap(normalized.range(of:"跨页段落甲")).lowerBound)
        }
    }
}
