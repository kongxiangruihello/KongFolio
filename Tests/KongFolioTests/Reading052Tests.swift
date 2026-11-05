import XCTest
import PDFKit
@testable import KongFolio

final class Reading052Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func citation(_ path:String,page:Int = 0)->ReadingCitation { ReadingCitation(source:SourceRef(path:path,fileName:"原书.pdf",page:page,pageLabel:"一"),title:"测试原书",author:"原作者",edition:"初版") }
    func testLegacyToolbarCollapsesWithoutDroppingOtherActions() throws {
        let suite="KongFolio052-"+UUID().uuidString,d=try XCTUnwrap(UserDefaults(suiteName:suite));defer{d.removePersistentDomain(forName:suite)}
        let old=ReaderToolbarProfile(order:["newPDF","newHTML","note","quickNote","essay","newText","open","newMarkdown","library"],pinned:["newPDF","newText"])
        old.save(d);let p=ReaderToolbarProfile.load(d)
        XCTAssertEqual(Array(p.actions.prefix(2)),[.newFile,.note]);XCTAssertEqual(p.actions.filter{$0 == .newFile}.count,1);XCTAssertEqual(p.actions.filter{$0 == .note}.count,1)
        XCTAssertEqual(Set(p.actions),Set(FileToolbarAction.allCases));XCTAssertEqual(p.pinned,["newFile"])
        XCTAssertEqual(p.visible(width:400)+p.hidden(width:400),p.actions)
        XCTAssertTrue(p.actions.contains(.comment))
    }
    func testOldEssayAndQuickNoteRemainSearchableAsNotesWithOriginalDates() async throws {
        let created=Date(timeIntervalSince1970:100),modified=Date(timeIntervalSince1970:200)
        let note=ReadingRecord(kind:.note,note:"旧速记内容",citations:[citation("/原书.pdf")],created:created,modified:modified)
        let essay=ReadingEssay(title:"旧札记名称",blocks:[ReadingEssay.Block(text:"旧论述",record:note)],created:created,modified:modified)
        let state=ReadingJournalState(records:[note],essays:[essay]);let reopened=try JSONDecoder().decode(ReadingJournalState.self,from:JSONEncoder().encode(state))
        let result=ReadingLibraryItem.results(reopened,kind:"笔记")
        XCTAssertEqual(Set(result.map(\.id)),[.record(note.id),.essay(essay.id)])
        XCTAssertTrue(result.allSatisfy{$0.kind == "笔记"});XCTAssertEqual(reopened, state)
        let hits=await ReadingSearchWorker.shared.records(reopened,query:"旧",notes:true,book:nil,tag:"",removed:false,recent:false)
        XCTAssertEqual(hits.count,2);XCTAssertEqual(reopened.essays[0].blocks[0].record?.citations,note.citations)
        let aliasNote=ReadingRecord(kind:.note,note:"旧路径笔记",citations:[citation("/private/tmp/KongFolio052-路径.pdf")])
        XCTAssertTrue(aliasNote.matches("旧路径",book:"/tmp/KongFolio052-路径.pdf"))
    }
    func makeDocument()->(PDFDocument,PDFPage,PDFAnnotation) {
        let doc=PDFDocument(),page=PDFPage();page.setBounds(CGRect(x:0,y:0,width:600,height:800),for:.mediaBox);doc.insert(page,at:0)
        let a=PDFAnnotation(bounds:CGRect(x:30,y:500,width:80,height:30),forType:.text,withProperties:nil);a.contents="PDF 评论正文";page.addAnnotation(a);return(doc,page,a)
    }
    func testPDFDatesIdentityAndSourceSurvivePDFSerialization() throws {
        let (doc,page,a)=makeDocument(),now=Date(timeIntervalSince1970:1700000000);ReadingPDFCapture.stampAdded(a,now:now);let id=AnnotationIdentity.id(of:a)
        let record=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:citation("/原书.pdf")))
        let copy=try XCTUnwrap(PDFDocument(data:try XCTUnwrap(doc.dataRepresentation()))),p=try XCTUnwrap(copy.page(at:0)),b=try XCTUnwrap(p.annotations.first)
        let restored=try XCTUnwrap(ReadingPDFCapture.record(b,page:p,index:0,source:citation("/原书.pdf")))
        XCTAssertEqual(restored.id,record.id);XCTAssertEqual(restored.pdfOrigin?.annotationID,id);XCTAssertEqual(restored.pdfOrigin?.originalCreated,now);XCTAssertEqual(restored.pdfOrigin?.originalModified,now)
        XCTAssertEqual(restored.pdfOrigin?.contents,a.contents);XCTAssertEqual(restored.citations[0].source.page,0);XCTAssertEqual(restored.citations[0].author,"原作者");XCTAssertEqual(restored.citations[0].source.rects,[b.bounds])
    }
    @MainActor func testMirrorPreservesPersonalWritingAndRetainsDeletedPDFRecords() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let journal=ReadingJournal(storage:root),(_,page,a)=makeDocument(),source=citation("/原书.pdf")
        let first=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:source));journal.mergePDFRecords([first],path:source.source.path,pages:nil)
        journal.editRecord(first.id){$0.title="我的标题";$0.note="独立的个人笔记";$0.tags=["史料"]};let created=try XCTUnwrap(journal.record(first.id)).created
        a.contents="PDF 更新的评论";a.modificationDate=Date(timeIntervalSince1970:1800000000)
        let updated=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:source));journal.mergePDFRecords([updated],path:source.source.path,pages:[0]);journal.mergePDFRecords([updated],path:source.source.path,pages:[0])
        let current=try XCTUnwrap(journal.record(first.id));XCTAssertEqual(journal.state.records.count,1);XCTAssertEqual(current.note,"独立的个人笔记");XCTAssertEqual(current.title,"我的标题");XCTAssertEqual(current.tags,["史料"]);XCTAssertEqual(current.created,created);XCTAssertEqual(current.pdfOrigin?.contents,"PDF 更新的评论")
        journal.mergePDFRecords([],path:source.source.path,pages:[0]);XCTAssertNotNil(journal.record(first.id)?.pdfOrigin?.missingSince);XCTAssertNil(journal.record(first.id)?.removed)
        journal.mergePDFRecords([updated],path:source.source.path,pages:[0]);XCTAssertNil(journal.record(first.id)?.pdfOrigin?.missingSince)
        try await journal.flush();let reopened=ReadingJournal(storage:root);XCTAssertEqual(reopened.record(first.id),journal.record(first.id))
    }
    @MainActor func testCopiedAnnotationIDsOnDifferentPagesNeverOverwriteOneAnother() throws {
        let j=ReadingJournal(storage:try folder()),(_,page,a)=makeDocument();a.setValue("same-pdf-id",forAnnotationKey:AnnotationIdentity.key)
        let a0=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:citation("/原书.pdf"))),a1=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:1,source:citation("/原书.pdf",page:1)))
        j.mergePDFRecords([a0,a1],path:"/原书.pdf",pages:nil);XCTAssertEqual(j.state.records.count,2);XCTAssertEqual(Set(j.state.records.map(\.id)).count,2)
        j.mergePDFRecords([a0],path:"/原书.pdf",pages:nil)
        XCTAssertNil(j.state.records.first{$0.citations[0].source.page==0}?.pdfOrigin?.missingSince);XCTAssertNotNil(j.state.records.first{$0.citations[0].source.page==1}?.pdfOrigin?.missingSince)
    }
    func testUnknownOriginalTimesAreExplicitAndExportsKeepProvenance() throws {
        let (_,page,a)=makeDocument();a.modificationDate=nil;a.userName="PDF 作者"
        let r=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:citation("/原书.pdf")))
        XCTAssertNil(r.pdfOrigin?.originalCreated);XCTAssertNil(r.pdfOrigin?.originalModified)
        let meta=ReadingRecordMetadata.lines(r).joined(separator:"\n");XCTAssertTrue(meta.contains("原创建时间：未记录"));XCTAssertTrue(meta.contains("收录时间："));XCTAssertTrue(meta.contains("PDF 作者"))
        let md=ReadingRecordExport.markdown(ReadingExportSnapshot(title:"导出",records:[r]),imageFolder:"Images")
        for text in ["PDF 评论正文","原作者","原书.pdf","PDF 第 1 页","收录时间","修改时间","kongfolio://source"] { XCTAssertTrue(md.contains(text),text) }
        XCTAssertTrue(r.hasContent)
    }
    func testWordAndPDFExportsRetainCommentSourceAndTime() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let (_,page,a)=makeDocument();ReadingPDFCapture.stampAdded(a,now:Date(timeIntervalSince1970:1700000000))
        var record=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:citation("/原书.pdf")))
        record.title="独立记录标题";record.note="个人补充文字"
        let snapshot=ReadingExportSnapshot(title:"来源与时间验证",records:[record])
        for format in [ReadingRecordExport.Format.pdf,.word] {
            let file=root.appendingPathComponent("验证."+format.ext)
            try ReadingRecordExport.write(snapshot,format:format,assets:root,to:file,expected:FileBaseline.capture(file))
            let text:String
            if format == .pdf { text=PDFDocument(url:file)?.string ?? "" }
            else {
                let package=try ReadingExportAudit.storedZIP(Data(contentsOf:file))
                let data=try XCTUnwrap(package["word/document.xml"])
                let document=try XMLDocument(data:data,options:[])
                var extracted=try document.nodes(forXPath:"//*[local-name()='t']").compactMap(\.stringValue).joined()
                if let comments=package["word/comments.xml"] { extracted += try XMLDocument(data:comments,options:[]).nodes(forXPath:"//*[local-name()='t']").compactMap(\.stringValue).joined() }
                text=extracted
            }
            // PDFKit can expose equivalent CJK radical code points and layout whitespace across OS versions.
            // Normalize compatibility glyphs, then verify every content character in the actual exported file.
            let extracted=text.precomposedStringWithCompatibilityMapping.filter{!$0.isWhitespace}
            for phrase in ["PDF 评论正文","个人补充文字","原作者","原书.pdf","原创建时间","原修改时间","收录时间"] {
                XCTAssertTrue(extracted.contains(phrase.precomposedStringWithCompatibilityMapping.filter{!$0.isWhitespace}),format.rawValue+": "+phrase+"; extracted: "+text)
            }
        }
    }
    @MainActor func testLiveAddEditDeleteAndUndoAreCapturedWithoutLosingSource() throws {
        let root=try folder(),url=root.appendingPathComponent("原书.pdf"),store=WorkspaceStore(storage:root),workspace=Workspace(storage:root)
        let (doc,page,a)=makeDocument();try XCTUnwrap(doc.dataRepresentation()).write(to:url)
        workspace.document=doc;workspace.sourceURL=url;workspace.store=store
        workspace.recordAnnotationsAdded([a]);let id=try XCTUnwrap(store.journal.state.records.first?.id)
        workspace.selectedAnnotation=a;workspace.note="在 PDF 中修改的评论";workspace.updateAnnotation()
        XCTAssertEqual(store.journal.record(id)?.pdfOrigin?.contents,"在 PDF 中修改的评论");XCTAssertFalse(try XCTUnwrap(store.journal.record(id)).citations[0].source.path.isEmpty)
        workspace.deleteAnnotation();XCTAssertNotNil(store.journal.record(id)?.pdfOrigin?.missingSince)
        workspace.undo();XCTAssertNil(store.journal.record(id)?.pdfOrigin?.missingSince);XCTAssertEqual(page.annotations.filter{$0.type == "Text"}.count,1);XCTAssertEqual(store.journal.state.records.count,1)
        workspace.clearDocument(keepingSource:false);XCTAssertNil(workspace.readingAnnotationTask)
    }
    @MainActor func testEditingAnImportedAnnotationWithAnEmptyIDKeepsOneRecord() throws {
        let root=try folder(),url=root.appendingPathComponent("原书.pdf"),store=WorkspaceStore(storage:root),workspace=Workspace(storage:root)
        let (doc,page,a)=makeDocument();a.setValue("",forAnnotationKey:AnnotationIdentity.key);try XCTUnwrap(doc.dataRepresentation()).write(to:url)
        workspace.document=doc;workspace.sourceURL=url;workspace.store=store
        let source=workspace.readingCitation(page:0),record=try XCTUnwrap(ReadingPDFCapture.record(a,page:page,index:0,source:source))
        store.journal.mergePDFRecords([record],path:source.source.path,pages:nil)
        workspace.selectedAnnotation=a;workspace.note="编辑已有 PDF 评论";workspace.updateAnnotation()
        XCTAssertEqual(store.journal.state.records.count,1);XCTAssertEqual(store.journal.record(record.id)?.pdfOrigin?.contents,"编辑已有 PDF 评论");XCTAssertNil(store.journal.record(record.id)?.pdfOrigin?.missingSince)
        workspace.clearDocument(keepingSource:false)
    }
    func testBackgroundImportIsReadOnlyAndRejectsChangedSources() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("原书.pdf"),(doc,_,_)=makeDocument(),bytes=try XCTUnwrap(doc.dataRepresentation());try bytes.write(to:url)
        let r=try await ReadingPDFImportWorker.shared.read(url,path:url.path,title:"原书",author:"作者",edition:"版本",expected:OCRPageCache.digest(bytes))
        XCTAssertEqual(r.count,1);XCTAssertEqual(try Data(contentsOf:url),bytes)
        var rejected=false;do { _=try await ReadingPDFImportWorker.shared.read(url,path:url.path,title:"原书",author:"",edition:"",expected:"wrong") } catch { rejected=true };XCTAssertTrue(rejected)
    }
}
