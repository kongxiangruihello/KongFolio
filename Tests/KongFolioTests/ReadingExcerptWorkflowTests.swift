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

    @MainActor func testQuickNoteStaysDraftUntilTypingAndKeepsEveryExcerptSource() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WorkspaceStore(storage:root)
        let first = excerpt("第一段",page:2)
        let second = excerpt("第二段",book:"史料乙",page:5)
        store.journal.add(first)
        store.startNoteFromExcerpt(first)
        let draft = try XCTUnwrap(store.journal.draftRecord)
        XCTAssertEqual(store.quickExcerptNoteID,draft.id)
        XCTAssertEqual(store.readingDeskSection,.notes)
        XCTAssertFalse(store.journal.state.records.contains{$0.id == draft.id})
        store.journal.editRecord(draft.id) { $0.note = "我的判断" }
        XCTAssertNil(store.journal.draftRecord)
        store.pinnedReadingID = draft.id
        store.journal.editRecord(first.id) { $0.appendExcerpt(second) }
        XCTAssertEqual(store.journal.appendExcerpt(first.id,toNote:draft.id),1)
        XCTAssertEqual(store.journal.appendExcerpt(first.id,toNote:draft.id),0)
        try await store.journal.flush()
        let saved = try XCTUnwrap(ReadingJournal(storage:root).record(draft.id))
        XCTAssertEqual(saved.note,"我的判断")
        XCTAssertEqual(saved.extras?.quotations?.map(\.text),["第一段","第二段"])
        XCTAssertEqual(saved.extras?.quotations?.map{$0.citations.first?.source.page},[2,5])
        XCTAssertEqual(saved.extras?.quotations?.map(\.originalCreated),[first.created,second.created])
    }

    @MainActor func testTopicNoteAndVersionsPreserveOrderAndReferenceTargets() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let first = excerpt("異文甲",page:1)
        let second = excerpt("異文乙",book:"史料乙",page:8)
        journal.add(first)
        journal.add(second)
        try journal.setExcerptVersions(first.id,second.id,linked:true)
        XCTAssertEqual(journal.record(first.id)?.extras?.versionExcerpts,[second.id])
        XCTAssertEqual(journal.record(second.id)?.extras?.versionExcerpts,[first.id])
        let id = try journal.makeTopicNote(title:"版本专题",excerpts:[second.id,first.id])
        let essay = try XCTUnwrap(journal.essay(id))
        XCTAssertEqual(essay.blocks.compactMap{$0.record?.id},[second.id,first.id])
        let reference = try XCTUnwrap(journal.references(to:.record(first.id)).incoming.first)
        XCTAssertEqual(reference.item,.essay(id))
        XCTAssertEqual(reference.target,.block(essay.blocks[1].id))
        try journal.setExcerptVersions(first.id,second.id,linked:false)
        XCTAssertNil(journal.record(first.id)?.extras?.versionExcerpts)
        XCTAssertNil(journal.record(second.id)?.extras?.versionExcerpts)
        let markdown = ReadingRecordExport.markdown(ReadingExportSnapshot(title:essay.title,essay:essay),imageFolder:"Assets")
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of:"異文乙")).lowerBound,
                          try XCTUnwrap(markdown.range(of:"異文甲")).lowerBound)
    }

    @MainActor func testQuotationBacklinkRefreshesOnlyReviewedCopy() throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let source = excerpt("原文")
        let a = ReadingRecord(kind:.note,note:"甲笔记")
        let b = ReadingRecord(kind:.note,note:"乙笔记")
        [source,a,b].forEach { journal.add($0) }
        XCTAssertEqual(journal.appendExcerpt(source.id,toNote:a.id),1)
        XCTAssertEqual(journal.appendExcerpt(source.id,toNote:b.id),1)
        let previous = try XCTUnwrap(journal.record(a.id)?.extras?.quotations?.first)
        journal.editRecord(source.id) { $0.quote = "校订后" }
        let incoming = journal.references(to:.record(source.id)).incoming
        XCTAssertTrue(incoming.contains{$0.item == .record(a.id) && $0.target == .quotation(previous.id)})
        let reviewed = try XCTUnwrap(journal.currentQuotation(previous))
        journal.editRecord(source.id) { $0.quote = "再校订" }
        XCTAssertThrowsError(try journal.refreshQuotation053(.record(a.id),quotation:previous.id,expected:previous,reviewed:reviewed))
        journal.editRecord(source.id) { $0.quote = "校订后" }
        try journal.refreshQuotation053(.record(a.id),quotation:previous.id,expected:previous)
        XCTAssertEqual(journal.record(a.id)?.extras?.quotations?.first?.text,"校订后")
        XCTAssertEqual(journal.record(a.id)?.extras?.quotations?.first?.captured,previous.captured)
        XCTAssertEqual(journal.record(b.id)?.extras?.quotations?.first?.text,"原文")
    }

    @MainActor func testTriageAndSentenceQuestionsPersistAndResolve() async throws {
        let root = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let passage = "先核对初刊。"
        let text = "第一段\n"+passage
        let note = ReadingRecord(kind:.note,note:text)
        var source = excerpt("待整理史料")
        source.extras = ReadingRecordExtras053(triage:.verify)
        journal.add(note)
        journal.add(source)
        let range = (text as NSString).range(of:passage)
        var question = try XCTUnwrap(ReadingFollowUp.capture(question:"哪一年初刊？",text:text,selection:range,block:nil))
        XCTAssertEqual(question.locate(in:"新增一段\n"+text).map{(("新增一段\n"+text) as NSString).substring(with:$0)},passage)
        XCTAssertNil(question.locate(in:passage+passage))
        journal.saveFollowUp(question,in:.record(note.id))
        var options = ReadingLibraryOptions053()
        options.triage = .verify
        let hits = await ReadingSearchWorker.shared.library(journal.state,request:ReadingSearchRequest(revision:journal.revisionID,options053:options))
        XCTAssertEqual(hits.map(\.id),[.record(source.id)])
        question.resolved = Date()
        journal.saveFollowUp(question,in:.record(note.id))
        try await journal.flush()
        let restored = ReadingJournal(storage:root)
        XCTAssertEqual(restored.record(note.id)?.extras?.followUps,[question])
        XCTAssertEqual(restored.record(source.id)?.extras?.triage,.verify)
    }

    func testCopyAndSearchSeparateOriginalCorrectionAndPersonalText() throws {
        var record = excerpt("校订引文",page:7)
        record.citations[0].source.pageLabel = "卷二·五"
        record.originalOCR = "未校引文"
        record.note = "我对引文的判断"
        let plain = ReadingCitationClipboardOptions(printedPage:false,sourceLink:false).text([record])
        XCTAssertTrue(plain.contains("校订引文"))
        XCTAssertTrue(plain.contains("第 8 页"))
        XCTAssertFalse(plain.contains("卷二·五"))
        let linked = ReadingCitationClipboardOptions(printedPage:true,sourceLink:true).text([record])
        XCTAssertTrue(linked.contains("卷二·五"))
        XCTAssertTrue(linked.contains("kongfolio"))
        let hits = ReadingTextSearch.fields(.record(record),query:"引文")
        XCTAssertEqual(hits.map(\.field),[.corrected,.original,.note])
        XCTAssertEqual(hits.map(\.matchedText),["引文","引文","引文"])
        XCTAssertEqual(ReadingTextSearch.fields(.record(record),query:"引文",scope:.mine).map(\.field),[.note])
        XCTAssertTrue(ReadingLibraryItem.record(record).searchText053(.quote).contains("未校引文"))
        let note = ReadingRecord(kind:.note,note:"个人分析",extras:ReadingRecordExtras053(quotations:record.frozenExcerptParts))
        let quoteHit = try XCTUnwrap(ReadingTextSearch.fields(.record(note),query:"引文",scope:.quote).first)
        XCTAssertTrue(quoteHit.identity.hasPrefix("quotation:"))
        XCTAssertTrue(ReadingLibraryItem.record(note).searchText053(.quote).contains("校订引文"))
    }


    func testVerticalColumnsCanBeLocatedReorderedAndCorrectedIndependently() throws {
        let right = RecognizedLine(text:"右列原識",box:CGRect(x:0.70,y:0.30,width:0.12,height:0.50))
        let left = RecognizedLine(text:"左列原識",box:CGRect(x:0.15,y:0.20,width:0.12,height:0.50))
        let segments = ReadingOCRSegments.make([left,right],vertical:true)
        XCTAssertEqual(segments.map(\.text),["右列原識","左列原識"])
        let frame = try XCTUnwrap(ReadingOCRSegments.previewRegion(segments[0].box,in:CGSize(width:300,height:500)))
        XCTAssertEqual(frame.minX,210,accuracy:0.001)
        XCTAssertEqual(frame.minY,100,accuracy:0.001)
        var revised = ReadingOCRSegments.ordered(segments,by:.leftToRight)
        revised[0].text = "左列校訂"
        XCTAssertEqual(ReadingOCRSegments.text(revised),"左列校訂\n右列原識")
        XCTAssertEqual(revised[0].original,"左列原識")
    }

}
