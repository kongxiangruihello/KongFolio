import XCTest
import AppKit
import SwiftUI
import PDFKit
@testable import KongFolio

final class Reading041LifecycleTests:XCTestCase {
    func folder() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("Reading041-"+UUID().uuidString); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url }

    @MainActor func testReadingExcerptNoteEssayAndSourceReturnPersistWithoutChangingPDF() async throws {
        _ = NSApplication.shared
        let root = try self.folder(), file = root.appendingPathComponent("跨页史料.pdf")
        let page = try RichTextDocument("这是用于阅读记录验证的史料原文。",format:.plain).pdf(), doc = PDFDocument()
        doc.insert(page.page(at:0)!.copy() as! PDFPage,at:0); doc.insert(page.page(at:0)!.copy() as! PDFPage,at:1)
        let bytes = try XCTUnwrap(doc.dataRepresentation()); try bytes.write(to:file)
        let store = WorkspaceStore(storage:root); store.readingMode = true; store.bootstrap(); let w = try XCTUnwrap(store.activeWorkspace)
        w.load([file],prepared:.documents([bytes])); w.bibliography = Bibliography(author:"作者甲",title:"阅读记录验证书")
        let host = NSHostingView(rootView:RootView(store:store)); host.frame = NSRect(x:0,y:0,width:1200,height:800); host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:80_000_000)
        let a = try XCTUnwrap(w.document.page(at:0)?.selection(for:NSRange(location:0,length:8))), b = try XCTUnwrap(w.document.page(at:1)?.selection(for:NSRange(location:0,length:8))); a.add(b)
        w.excerpt(selection:a); let record = try XCTUnwrap(store.journal.record(store.readingRecordID))
        XCTAssertEqual(record.citations.count,2); XCTAssertEqual(record.citations.first?.author,"作者甲"); XCTAssertEqual(record.citations.first?.title,"阅读记录验证书"); XCTAssertTrue(store.board.cards.isEmpty)
        store.newReadingNote(linked:record); let note = try XCTUnwrap(store.readingRecordID); store.journal.editRecord(note) { $0.note = "我的论断与原文分开" }
        let essay = store.journal.newEssay(title:"跨书札记"); store.journal.insert(record,in:essay); store.journal.editEssay(essay) { $0.blocks[0].text = "先提出自己的论点" }
        w.selectPage(1); XCTAssertTrue(store.reveal(record.citations[0].source,beside:false)); XCTAssertEqual(w.selection,0)
        try await store.journal.flush(); let reopened = ReadingJournal(storage:root); XCTAssertEqual(reopened.record(note)?.note,"我的论断与原文分开"); XCTAssertEqual(reopened.essay(essay)?.blocks[0].text,"先提出自己的论点")
        XCTAssertEqual(try Data(contentsOf:file),bytes); XCTAssertTrue(w.document.page(at:0)!.annotations.isEmpty)
        host.rootView = RootView(store:WorkspaceStore(storage:try self.folder())); host.layoutSubtreeIfNeeded()
    }
    @MainActor func testTextPreviewDividerRespondsWithoutRecreatingTextEditor() async throws {
        _ = NSApplication.shared
        let key = "KongFolio.textPreviewEditorFraction", old = UserDefaults.standard.object(forKey:key)
        defer { if let old { UserDefaults.standard.set(old,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }
        UserDefaults.standard.set(0.3,forKey:key)
        let note = MarkdownNote(text:"# 可调预览\n\n保留编辑器",storage:try self.folder())
        let host = NSHostingView(rootView:AnyView(TextEditorPreviewSplit(note:note))); host.frame = NSRect(x:0,y:0,width:1000,height:600)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:80_000_000); host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(note.textView), first = try XCTUnwrap(view.enclosingScrollView).frame.width
        UserDefaults.standard.set(0.7,forKey:key); try await Task.sleep(nanoseconds:120_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(note.textView === view); XCTAssertTrue((view.enclosingScrollView?.frame.width ?? 0)-first > 200)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
    }
    @MainActor func testPlainTextEditorHasNoPDFPreviewEvenWhenOldPreviewExists() async throws {
        _ = NSApplication.shared
        let note = MarkdownNote(text:"纯文本",storage:try self.folder(),format:.plain)
        let old = PDFDocument(); old.insert(PDFPage(),at:0); note.preview = old
        let host = NSHostingView(rootView:AnyView(TextEditorPreviewSplit(note:note))); host.frame = NSRect(x:0,y:0,width:1000,height:600)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:80_000_000)
        XCTAssertNil(ResearchPreviewLifecycleTests().find(host)); XCTAssertTrue((note.textView?.enclosingScrollView?.frame.width ?? 0) > 950)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
    }
}
