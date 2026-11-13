import XCTest
import AppKit
@testable import KongFolio

final class EditorDisplayTests: XCTestCase {
    func testDisplaySettingsSurviveReloadAndRejectInvalidValues() {
        let defaults = UserDefaults(suiteName:UUID().uuidString)!
        var options = EditorDisplayOptions();XCTAssertEqual(options.size,18);options.size = 24;options.face = .serif;options.column = .wide;options.save(defaults)
        XCTAssertEqual(EditorDisplayOptions.load(defaults),options)
        options.size = 500;defaults.set(try! JSONEncoder().encode(options),forKey:EditorDisplayOptions.key)
        XCTAssertEqual(EditorDisplayOptions.load(defaults),EditorDisplayOptions())
    }
    func testColumnFitsSmallAndLargeWindowsWithoutNegativeInsets() {
        var options = EditorDisplayOptions()
        XCTAssertEqual(options.inset(viewport:1280),260)
        XCTAssertEqual(options.inset(viewport:340),16)
        options.column = .full;XCTAssertEqual(options.inset(viewport:1280),28)
        for width in stride(from:260.0,through:2400,by:20) { XCTAssertTrue(width-2*options.inset(viewport:width)>=220) }
    }
    @MainActor func testDisplayChangesPreserveChineseTextSelectionAndUndo() {
        let view = DisplayTextView(frame:NSRect(x:0,y:0,width:1200,height:400));view.isRichText = false;view.allowsUndo = true
        view.string = "甲😀\n- 第一条\n- 第二条";view.setSelectedRange(NSRange(location:3,length:0))
        view.insertText("新增",replacementRange:view.selectedRange());let body = view.string,selection = view.selectedRange()
        XCTAssertTrue(view.undoManager!.canUndo)
        var options = EditorDisplayOptions();options.size = 24;options.face = .serif;view.displayOptions = options
        XCTAssertEqual(view.string,body);XCTAssertEqual(view.selectedRange(),selection);XCTAssertEqual(view.font!.pointSize,24)
        view.undoManager!.undo();XCTAssertEqual(view.string,"甲😀\n- 第一条\n- 第二条")
        view.undoManager!.redo();XCTAssertEqual(view.string,body)
    }
    @MainActor func testMarkedCompositionDefersDisplayUntilCommit() {
        let view = DisplayTextView(frame:NSRect(x:0,y:0,width:900,height:400));view.isRichText = false;view.displayOptions = EditorDisplayOptions();view.string = "开头"
        view.setSelectedRange(NSRange(location:2,length:0));view.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:view.selectedRange())
        XCTAssertTrue(view.hasMarkedText());let original = view.string,marked = view.markedRange()
        var options = EditorDisplayOptions();options.size = 26;view.displayOptions = options
        XCTAssertEqual(view.string,original);XCTAssertEqual(view.markedRange(),marked);XCTAssertEqual(view.font!.pointSize,18)
        view.insertText("中",replacementRange:view.markedRange());view.unmarkText()
        XCTAssertEqual(view.string,"开头中");XCTAssertEqual(view.font!.pointSize,26)
    }
    @MainActor func testPresentationDoesNotPublishContentOrEraseListUndo() {
        var text = "- 第一行\n- 第二行";let view = DisplayTextView(frame:NSRect(x:0,y:0,width:800,height:400));view.isRichText = false;view.string = text;view.supportsMarkdownLists = true
        let input = StableInputCoordinator(read:{text},write:{text = $0});view.committed = { input.publish($0) }
        view.setSelectedRange(NSRange(location:5,length:0));view.insertNewline(nil);let edited = view.string;XCTAssertEqual(text,edited)
        var options = EditorDisplayOptions();options.size = 22;view.displayOptions = options;view.setFrameSize(NSSize(width:420,height:400));input.synchronize(view)
        XCTAssertEqual(view.string,edited);XCTAssertEqual(text,edited);view.undoManager!.undo();XCTAssertEqual(view.string,"- 第一行\n- 第二行")
    }
    @MainActor func testNewMarkdownStartsInContinuousEditorWithPreviewOnDemand() async throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = WorkspaceStore(storage:folder,readingDefaults:Release037Tests().suite())
        let note = store.newNote()
        XCTAssertEqual(note.format,.markdown)
        XCTAssertTrue(note.focusNewEditor)
        XCTAssertFalse(note.cleanEditing)
        XCTAssertFalse(note.showPreview)
        XCTAssertTrue(note.text.isEmpty)
        let plain = store.newNote(format:.plain)
        XCTAssertEqual(plain.format,.plain)
        XCTAssertTrue(plain.focusNewEditor)
        XCTAssertFalse(plain.showPreview)
        let html = store.newNote(format:.html)
        XCTAssertTrue(html.focusNewEditor)
        XCTAssertFalse(html.showPreview)

        note.text = "# 写作\n\n正文"
        XCTAssertNil(note.preview)
        note.showPreview = true
        let deadline = Date().addingTimeInterval(5)
        while note.preview == nil && note.previewMessage.isEmpty && Date() < deadline {
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertEqual(note.preview?.pageCount,1,note.previewMessage)
        XCTAssertEqual(note.text,"# 写作\n\n正文")
        note.showPreview = false
        XCTAssertNil(note.preview)
    }
    @MainActor func testRightPanelRoutingDoesNotOpenUnexpectedWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(storage:folder);store.readingMode = false
        store.showReadingPanel(.notes)
        XCTAssertTrue(store.readingMode);XCTAssertTrue(store.showReadingDesk);XCTAssertEqual(store.readingDeskSection,.notes);XCTAssertNil(store.readingDeskWindowRequest)
        store.showReadingPanel(.essays);XCTAssertEqual(store.readingDeskSection,.essays);XCTAssertNil(store.readingDeskWindowRequest)
    }
    @MainActor func testIndependentLibraryWindowDoesNotAlsoOpenSidePanel() {
        let store = WorkspaceStore(storage:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.openReadingDesk(.search,window:true)
        XCTAssertNotNil(store.readingDeskWindowRequest);XCTAssertFalse(store.showReadingDesk)
    }
    func testMarkdownToolbarDistributesExtraWidthWithoutCompressingButtons() {
        let widths: [CGFloat] = [24,42,30,28]
        XCTAssertEqual(MarkdownToolbarRow.spacing(width:484,itemWidths:widths),120)
        XCTAssertEqual(MarkdownToolbarRow.spacing(width:148,itemWidths:widths),8)
        XCTAssertEqual(MarkdownToolbarRow.spacing(width:110,itemWidths:widths),8)
        XCTAssertEqual(MarkdownToolbarRow.spacing(width:160,itemWidths:[28]),0)
    }

    @MainActor func testFunctionToolbarHidesDuringTextFileEditing() {
        let markdown = MarkdownNote(format:.markdown)
        XCTAssertFalse(RootView.showsFunctionToolbar(for:.note(markdown)))
        markdown.cleanEditing = true
        XCTAssertFalse(RootView.showsFunctionToolbar(for:.note(markdown)))
        markdown.readOnly = true
        XCTAssertTrue(RootView.showsFunctionToolbar(for:.note(markdown)))
        let html = MarkdownNote(format:.html)
        XCTAssertFalse(RootView.showsFunctionToolbar(for:.note(html)))
        html.readOnly = true
        XCTAssertTrue(RootView.showsFunctionToolbar(for:.note(html)))
        let plain = MarkdownNote(format:.plain)
        XCTAssertFalse(RootView.showsFunctionToolbar(for:.note(plain)))
        plain.readOnly = true
        XCTAssertTrue(RootView.showsFunctionToolbar(for:.note(plain)))
        XCTAssertTrue(RootView.showsFunctionToolbar(for:nil))
    }

    func testToolbarLeavesRoomForAlwaysVisiblePanelSelector() {
        for width in stride(from:320.0,through:1600,by:5) {
            XCTAssertTrue(Double(SingleRowToolbarPolicy.visibleCount(width:width))*36+198<=width)
            let profile = ReaderToolbarProfile();XCTAssertEqual(Set(profile.visible(width:width)+profile.hidden(width:width)),Set(FileToolbarAction.allCases))
        }
    }
}
