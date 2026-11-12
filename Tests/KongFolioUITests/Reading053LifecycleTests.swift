import XCTest
import SwiftUI
import PDFKit
import AppKit
@testable import KongFolio

final class Reading053LifecycleTests: XCTestCase {
    @MainActor func wait(_ stage:String = "生成文献验证",_ predicate:@escaping ()->Bool) async throws {
        for _ in 0..<2000 { if predicate() { return };try await Task.sleep(nanoseconds:5_000_000) }
        throw NSError(domain:"Reading053Lifecycle",code:1,userInfo:[NSLocalizedDescriptionKey:stage+"等待超时"])
    }
    @MainActor func testTenMixedRoundsOfTwentyFilesStayOperable() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio053-mixed-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var files:[URL]=[]
        for i in 0..<16 {
            let file=root.appendingPathComponent("generated-\(i).pdf"),document=PDFDocument()
            let count=i==15 ? 120:3
            for p in 0..<count { let page=PDFPage();page.setBounds(CGRect(x:0,y:0,width:600,height:800),for:.mediaBox);document.insert(page,at:p) }
            try document.dataRepresentation()!.write(to:file);files.append(file)
        }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1400,pixelsHigh:1900,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let graphic=NSGraphicsContext(bitmapImageRep:bitmap)!;NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphic
        NSColor.white.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:1400,height:1900)).fill()
        for i in 0..<60 { NSColor.black.setFill();NSBezierPath(rect:CGRect(x:40,y:40+i*28,width:1100-i*3,height:5)).fill() }
        NSGraphicsContext.restoreGraphicsState();let image=NSImage(size:NSSize(width:1400,height:1900));image.addRepresentation(bitmap)
        let scan=PDFDocument();scan.insert(PDFPage(image:image)!,at:0);let scanFile=root.appendingPathComponent("generated-scan.pdf");try scan.dataRepresentation()!.write(to:scanFile);files.append(scanFile)
        let encrypted=PDFDocument();encrypted.insert(PDFPage(),at:0);let locked=root.appendingPathComponent("generated-encrypted.pdf");XCTAssertTrue(encrypted.write(to:locked,withOptions:[.userPasswordOption:"generated",.ownerPasswordOption:"owner"]));files.append(locked)
        for i in 0..<2 { let bad=root.appendingPathComponent("generated-corrupt-\(i).pdf");try Data("%PDF-1.7\ninvalid generated fixture".utf8).write(to:bad);files.append(bad) }
        let suite="KongFolio053-memory-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(2,forKey:"KongFolio.maximumLoadedTabs")
        let store=WorkspaceStore(storage:root.appendingPathComponent("Support"),readingDefaults:defaults);store.bootstrap()
        let host=NSHostingView(rootView:RootView(store:store));host.frame=NSRect(x:0,y:0,width:1000,height:700)
        var samples:[Double]=[]
        for round in 0..<10 {
            store.openEach(files)
            let tabs=store.tabs.compactMap(\.workspace).filter{$0.sourceURL != nil}
            XCTAssertEqual(tabs.count,20)
            for workspace in tabs {
                store.select(workspace.id);host.layoutSubtreeIfNeeded()
                try await wait{!workspace.isImporting && !workspace.busy && (workspace.count>0 || workspace.error != nil)}
                if let url=workspace.sourceURL,url.lastPathComponent.contains("encrypted") || url.lastPathComponent.contains("corrupt") { XCTAssertNotNil(workspace.error) }
                else { XCTAssertTrue(workspace.count>0);workspace.selectPage(max(0,workspace.count-1));XCTAssertEqual(workspace.selection,workspace.count-1) }
                store.close(workspace.id)
                try await wait{!store.tabs.contains(where:{$0.id==workspace.id}) || (store.tabs.count==1 && store.activeWorkspace?.count==0)}
                try await Task.sleep(nanoseconds:2_000_000)
            }
            autoreleasepool { host.layoutSubtreeIfNeeded() }
            try await Task.sleep(nanoseconds:30_000_000)
            samples.append(ReadingLifecycleTests().residentMB())
            XCTAssertTrue(store.tabs.count<=1);XCTAssertFalse(store.activeWorkspace?.busy ?? false)
            print("READING053_MIXED_ROUND",round+1,"MB",samples.last!)
        }
        if let first=samples.first,let last=samples.last { XCTAssertTrue(last-first<250,"多轮释放后的内存增长过大") }
        host.rootView=RootView(store:WorkspaceStore(storage:root.appendingPathComponent("Empty")));host.layoutSubtreeIfNeeded()
    }
    @MainActor func testPendingCloudDownloadDoesNotBlockThreeBatchesOfReading() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-cloud-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let suite = "KongFolio-cloud-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = WorkspaceStore(storage:root.appendingPathComponent("Support"),readingDefaults:defaults)
        let files = (0..<20).map { index -> URL in
            let file = root.appendingPathComponent("文献-\(index).pdf")
            let document = PDFDocument()
            for _ in 0..<2 { document.insert(PDFPage(),at:document.pageCount) }
            XCTAssertTrue(document.write(to:file))
            return file
        }

        for round in 1...3 {
            switch round {
            case 1: store.openEach(files)
            case 2:
                let finder = ExternalDocumentRouter()
                finder.attach(store)
                finder.receive(files)
            default: store.activeWorkspace?.openDropped(files)
            }
            XCTAssertEqual(store.readingBatch?.entries.count,20)
            let cloud = try XCTUnwrap(store.tabs.compactMap(\.workspace).first{$0.sourceURL == files.last})
            let waitingURL = cloud.sourceURL
            cloud.prepareImportFiles = { urls, progress in
                guard urls.first == waitingURL else { return }
                progress("正在下载 iCloud 文件")
                try await Task.sleep(nanoseconds:60_000_000_000)
            }
            store.select(cloud.id)
            try await wait("第 \(round) 轮云文件开始准备") { cloud.isImporting && cloud.taskLabel.contains("iCloud") }
            let locals = store.tabs.compactMap(\.workspace).filter { $0.id != cloud.id && $0.sourceURL != nil }
            XCTAssertEqual(locals.count,19)
            for local in locals {
                store.select(local.id)
                try await wait("第 \(round) 轮载入 \(local.displayName)") { (local.count == 2 || local.error != nil) && !local.busy }
                XCTAssertEqual(local.count,2,local.error ?? local.status)
                XCTAssertTrue(cloud.isImporting)
                local.selectPage(1)
                XCTAssertEqual(local.selection,1)
                store.close(local.id)
                try await wait("第 \(round) 轮关闭 \(local.displayName)") { !store.tabs.contains(where:{$0.id == local.id}) }
            }
            store.close(cloud.id)
            try await wait("第 \(round) 轮取消云下载") { !cloud.isImporting && !cloud.busy }
            XCTAssertNil(cloud.error)
        }
    }

    @MainActor func testLibraryNoteEditorSurvivesSaveListPasteUndoAndSwitch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-input-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = ReadingJournal(storage:root)
        let note = ReadingRecord(kind:.note,note:"- 首行\n- 第二行")
        let other = ReadingRecord(kind:.note,note:"另一条笔记")
        journal.add(note)
        journal.add(other)
        try await journal.flush()
        let session = WritingSession()
        func editor(_ id:UUID) -> AnyView {
            AnyView(StableTextEditor(text:Binding(get:{journal.record(id)?.note ?? ""},set:{ body in
                journal.editRecord(id) { $0.note = body }
            }),label:"资料库笔记",identity:id.uuidString,session:session,markdown:true).id(id))
        }
        let host = NSHostingView(rootView:editor(note.id))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:270),
                              styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await wait { session.view != nil }
        let view = try XCTUnwrap(session.view as? ComposingTextView)
        let caret = NSRange(location:4,length:0)
        view.setSelectedRange(caret)
        view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:caret)
        try await journal.flush()
        XCTAssertEqual(journal.record(note.id)?.note,note.note)
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("中",replacementRange:view.markedRange())
        XCTAssertEqual(view.selectedRange(),NSRange(location:5,length:0))
        view.breakUndoCoalescing()
        view.insertNewline(nil)
        XCTAssertEqual(view.string,"- 首行中\n- \n- 第二行")
        let inserted = String(repeating:"长篇史料和中文段落。",count:300)
        view.insertText(inserted,replacementRange:view.selectedRange())
        XCTAssertTrue(journal.record(note.id)?.note.contains(inserted) == true)
        view.breakUndoCoalescing()
        view.undoManager?.undo()
        XCTAssertFalse(view.string.contains(inserted))
        let expected = view.string
        let finalSelection = NSRange(location:1,length:2)
        view.setSelectedRange(finalSelection)
        host.rootView = editor(other.id)
        host.layoutSubtreeIfNeeded()
        try await wait { session.view?.string == other.note }
        host.rootView = editor(note.id)
        host.layoutSubtreeIfNeeded()
        try await wait { session.view?.string == expected && session.view?.selectedRange() == finalSelection }
        try await journal.flush()
        XCTAssertEqual(ReadingJournal(storage:root).record(note.id)?.note,expected)
        XCTAssertEqual(journal.record(other.id)?.note,other.note)
    }

    @MainActor func testNativeCanvasImageWidthIsExactAndSourceFlashDoesNotEditPDF() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-placement-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let workspace = Workspace(storage:root)
        let page = PDFPage()
        page.setBounds(CGRect(x:0,y:0,width:400,height:500),for:.mediaBox)
        page.rotation = 90
        workspace.document.insert(page,at:0)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:640,height:550),
                              styleMask:[.borderless],backing:.buffered,defer:false)
        let view = DrawingPDFView(frame:window.contentLayoutRect)
        window.contentView = view
        view.document = workspace.document
        view.workspace = workspace
        workspace.pdfView = view
        view.autoScales = true
        view.go(to:page)
        view.layoutDocumentView()
        let context = try XCTUnwrap(CGContext(data:nil,width:80,height:40,bitsPerComponent:8,bytesPerRow:0,
                                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        workspace.beginPlacingPageImage(image,png:try XCTUnwrap(SignatureImage.pngData(image)),on:page)
        workspace.setPageImageWidth(72)
        XCTAssertEqual(try XCTUnwrap(workspace.pageImageWidthPoints),72,accuracy:0.15)
        let placement = try XCTUnwrap(view.signaturePlacement())
        XCTAssertEqual(placement.rect.height/placement.rect.width,2,accuracy:0.01)
        workspace.cancelSignaturePlacement()

        let originalSubViewCount = view.subviews.count
        view.showSourceHighlight([CGRect(x:25,y:25,width:70,height:50)],on:page,keep:false)
        XCTAssertEqual(view.subviews.count,originalSubViewCount+1)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.dirty)
        try await wait("原文选区高亮消退") { view.subviews.count == originalSubViewCount }
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor func testQuickExcerptNoteFocusAndEscapeReturnToPDF() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-quick-note-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = WorkspaceStore(storage:folder)
        let workspace = store.newPDF()
        let excerpt = ReadingRecord(kind:.excerpt,quote:"读到的一段原文")
        store.journal.add(excerpt)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1100,height:700),
                              styleMask:[.titled],backing:.buffered,defer:false)
        let host = NSHostingView(rootView:RootView(store:store))
        window.contentView = host
        host.frame = NSRect(x:0,y:0,width:1100,height:700)
        host.layoutSubtreeIfNeeded()
        try await wait("准备测试 PDF") { workspace.pdfView != nil }
        store.startNoteFromExcerpt(excerpt)
        let id = try XCTUnwrap(store.quickExcerptNoteID)
        try await wait("摘录笔记正文取得焦点") {
            host.layoutSubtreeIfNeeded()
            return (window.firstResponder as? ComposingTextView)?.positionKey == "note:"+id.uuidString
        }
        let view = try XCTUnwrap(window.firstResponder as? ComposingTextView)
        XCTAssertTrue(view.string.isEmpty)
        view.cancelOperation(nil)
        XCTAssertTrue(window.firstResponder === workspace.pdfView)
        XCTAssertNil(store.journal.draftRecord)
        XCTAssertFalse(store.journal.state.records.contains{$0.id == id})
    }

    @MainActor func testModelessFileChooserHandsOffOnceAndCanReopenAfterCancel() async throws {
        _ = NSApplication.shared
        let chooser = DocumentChooserCoordinator()
        let first = TestDocumentPanel()
        let url = URL(fileURLWithPath:"/tmp/generated-test-document.pdf")
        first.selected = [url]
        var deliveries: [[URL]] = []
        chooser.present(first,presentation:.separate) { response, urls in
            XCTAssertEqual(response,.OK)
            deliveries.append(urls)
        }
        XCTAssertTrue(chooser.panel === first)
        XCTAssertEqual(first.separateStarts,1)
        XCTAssertEqual(first.sheetStarts,0)
        let old = try XCTUnwrap(first.completion)
        old(.OK)
        old(.OK)
        XCTAssertNil(chooser.panel)
        XCTAssertTrue(deliveries.isEmpty)
        try await wait("交接文件选择结果") { deliveries.count == 1 }
        XCTAssertEqual(deliveries,[[url]])

        let next = TestDocumentPanel()
        next.selected = [url]
        chooser.present(next,presentation:.separate) { response, urls in
            XCTAssertEqual(response,.cancel)
            deliveries.append(urls)
        }
        next.completion?(.cancel)
        try await wait("取消后的回调") { deliveries.count == 2 }
        XCTAssertEqual(deliveries.last,[])
        XCTAssertNil(chooser.panel)
    }

    @MainActor private final class TestDocumentPanel: NSOpenPanel {
        var selected: [URL] = []
        var completion: ((NSApplication.ModalResponse) -> Void)?
        var separateStarts = 0
        var sheetStarts = 0

        override var urls: [URL] { selected }
        override func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
            separateStarts += 1
            completion = handler
        }
        override func beginSheetModal(for sheetWindow:NSWindow,completionHandler handler:@escaping(NSApplication.ModalResponse)->Void) {
            sheetStarts += 1
            completion = handler
        }
    }

    @MainActor func testTwoNativeEditorsRetainConcurrentTextWithoutResettingComposition() {
        var text="甲乙丙丁"
        let a=StableInputCoordinator(read:{text},write:{text=$0}),b=StableInputCoordinator(read:{text},write:{text=$0}),va=ComposingTextView(),vb=ComposingTextView()
        va.string="甲新乙丙丁";vb.string="甲乙丙新丁";a.publish(va);b.publish(vb)
        XCTAssertEqual(text,"甲新乙丙新丁")
        va.setMarkedText("中文输入",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:0,length:0));let marked=va.string
        a.synchronize(va);XCTAssertEqual(va.string,marked);XCTAssertTrue(va.hasMarkedText())
    }
}
