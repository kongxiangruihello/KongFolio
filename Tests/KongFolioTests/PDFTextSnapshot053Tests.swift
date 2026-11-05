import XCTest
import AppKit
import PDFKit
import CoreText
@testable import KongFolio

@MainActor final class PDFTextSnapshot053Tests: XCTestCase {
    func fixture(_ folder:URL) throws -> URL {
        let data=NSMutableData(),consumer=try XCTUnwrap(CGDataConsumer(data:data))
        let context=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:nil,nil))
        for index in 0..<3 {
            var box=CGRect(x:0,y:0,width:600,height:800);context.beginPage(mediaBox:&box)
            let font=CTFontCreateWithName("PingFang SC" as CFString,22,nil)
            let line="第 \(index+1) 页 · 海关史料 · PageUnique\(index+1) FindPage\(index+1)Only"
            let text=NSAttributedString(string:line,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
            context.textPosition=CGPoint(x:35,y:710);CTLineDraw(CTLineCreateWithAttributedString(text),context)
            context.endPage()
        }
        context.closePDF()
        let file=folder.appendingPathComponent("searchable.pdf");try (data as Data).write(to:file);return file
    }
    func text(_ document:PDFDocument)->[String] {
        // PDFKit may emit the equivalent simplified page radical, which Unicode NFKC leaves alone.
        (0..<document.pageCount).map{(document.page(at:$0)?.string ?? "").precomposedStringWithCompatibilityMapping.replacingOccurrences(of:"⻚",with:"页")}
    }
    func workspace(_ file:URL,_ root:URL)throws->Workspace {
        let w=try Release038Tests().open(file,storage:root);w.readingLocked=false;return w
    }
    func verify(_ bytes:Data,_ expected:[String])throws {
        let reopened=try XCTUnwrap(PDFDocument(data:bytes));XCTAssertEqual(text(reopened),expected)
        XCTAssertEqual(reopened.findString("FindPage2Only",withOptions:[]).count,1)
        XCTAssertEqual(reopened.findString("海关史料",withOptions:[]).count,3)
        XCTAssertEqual(reopened.page(at:1)?.annotations.first?.contents,"保存后保留的评论")
    }
    func testCompleteAndIncrementalTextSnapshotsKeepEveryPageGlyphMap() async throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=try fixture(root),w=try workspace(file,root),expected=text(w.document)
        XCTAssertTrue(SnapshotSafety.requiresOriginalSerialization(w.document))
        let annotation=PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.text,withProperties:nil)
        annotation.contents="保存后保留的评论";w.document.page(at:1)!.addAnnotation(annotation);w.edited(pages:[1])
        let incremental=try await w.snapshotForBackgroundSave();try verify(incremental.pdf,expected)
        w.cachedPDF=nil;w.incrementalBase=nil;w.incrementalPages=[]
        let full=try await w.snapshotForBackgroundSave();try verify(full.pdf,expected)
        try full.pdf.write(to:file);try verify(Data(contentsOf:file),expected)
    }
    func testPageAddDeleteUndoRedoAndReopenKeepSearchableChineseAndASCII() async throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=try fixture(root),w=try workspace(file,root),expected=text(w.document)
        let annotation=PDFAnnotation(bounds:CGRect(x:10,y:10,width:20,height:20),forType:.text,withProperties:nil)
        annotation.contents="保存后保留的评论";w.document.page(at:1)!.addAnnotation(annotation);w.edited(pages:[1])
        _ = try await w.snapshotForBackgroundSave()
        w.selectPage(2);w.insertBlankPage();XCTAssertEqual(w.count,4)
        _ = try await w.snapshotForBackgroundSave()
        w.selectedPages=[3];w.remove();XCTAssertEqual(w.count,3)
        let removed=try await w.snapshotForBackgroundSave();try verify(removed.pdf,expected)
        w.undo();XCTAssertEqual(w.count,4);w.redo();XCTAssertEqual(w.count,3)
        let redone=try await w.snapshotForBackgroundSave();try verify(redone.pdf,expected)
        try w.restore(redone);try verify(w.pdfData(),expected)
    }
    func testImportAndDuplicateTextPagesKeepDistinctSearchTerms() async throws {
        let root=try Release027Tests().folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=try fixture(root),w=try workspace(file,root),expected=text(w.document)
        w.selectPage(1);w.selectedPages=[1];w.duplicatePages()
        let archive=try await w.snapshotForBackgroundSave(),reopened=try XCTUnwrap(PDFDocument(data:archive.pdf))
        XCTAssertEqual(text(reopened),[expected[0],expected[1],expected[1],expected[2]])
        XCTAssertEqual(reopened.findString("FindPage2Only",withOptions:[]).count,2)
        w.undo();XCTAssertEqual(text(w.document),expected)
    }
}
