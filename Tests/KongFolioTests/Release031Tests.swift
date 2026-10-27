import XCTest
import AppKit
import PDFKit
@testable import KongFolio

final class Release031Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func pdf(_ texts: [String]) throws -> Data { try Release027Tests().pdf(texts) }
    func link(in text: String) throws -> SourceRef {
        let regex = try NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#)
        let found = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)))
        return try XCTUnwrap(SourceLink.source(URL(string: (text as NSString).substring(with: found.range))!))
    }
    @MainActor func testCurrentOnlySearchNeedsNoFolderAndUsesUnsavedBuffer() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), note = store.newNote(); note.text = "历史 history 未保存"
        let model = store.folderSearch; model.scope = .current; model.query = "history"; model.folder = URL(fileURLWithPath: "/does-not-exist")
        model.start(live: try store.searchSnapshots()); try await Release027Tests().wait(model)
        XCTAssertEqual(model.results.count, 1); XCTAssertEqual(model.results[0].tabID, note.id); XCTAssertNil(model.searchedFolder)
        XCTAssertTrue(model.report().contains("仅当前编辑和摘录"))
    }
    @MainActor func testFolderOnlySearchIgnoresPassedLiveSnapshots() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try "history disk".write(to: root.appendingPathComponent("disk.md"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(storage: root.appendingPathComponent("app")), note = store.newNote(); note.text = "history live"
        let model = store.folderSearch; model.scope = .folder; model.folder = root; model.query = "history"
        model.start(live: try store.searchSnapshots()); try await Release027Tests().wait(model)
        XCTAssertEqual(model.results.count, 1); XCTAssertNil(model.results[0].tabID); XCTAssertTrue(model.results[0].hit.snippet.contains("disk"))
    }
    @MainActor func testSearchPreferencesPersistAndOldSettingsStillDecode() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = FolderSearchModel(storage: root); model.scope = .current; model.bodyOnly = false; model.includeAnnotations = false; model.grouped = false; model.remember()
        let restored = FolderSearchModel(storage: root)
        XCTAssertEqual(restored.scope, .current); XCTAssertFalse(restored.bodyOnly); XCTAssertFalse(restored.includeAnnotations); XCTAssertFalse(restored.grouped)
        let old = try JSONDecoder().decode(FolderSearchModel.Settings.self, from: Data(#"{"recursive":true,"query":"history"}"#.utf8))
        XCTAssertNil(old.scope); XCTAssertNil(old.bodyOnly)
    }
    func testHTMLBodyExcludesScriptsStylesAttributesAndDecodesEntities() {
        let text = "<head><title>hidden-title</title></head><style>hidden-css</style><script>hidden-script</script><p title='secret'>😀 历<b>史</b>&amp;档案&#x20000;</p>"
        let body = TextSearchBody.make(text, format: .html)
        XCTAssertFalse(body.text.contains("hidden")); XCTAssertFalse(body.text.contains("secret")); XCTAssertTrue(body.text.contains("😀 历史&档案𠀀"))
        var cache: [String:String] = [:]
        let hits = FolderSearchService.matches(body.page(format: .html, bodyOnly: true), query: "历史&档案𠀀", limit: 10, cache: &cache)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual((text as NSString).substring(with: hits[0].range), "历<b>史</b>&amp;档案&#x20000;")
    }
    func testHTMLUnclosedHiddenBlockDoesNotLeakAndInlineWordsJoin() {
        let body = TextSearchBody.make("<p>hist<strong>ory</strong></p><script>not visible", format: .html)
        XCTAssertTrue(body.text.contains("history")); XCTAssertFalse(body.text.contains("not visible"))
    }
    func testMarkdownBodySearchKeepsLabelsButDropsURLsAndMarkers() {
        let source = "# 历史\n\n[档案](https://secret.test/hidden-url) ![图片说明](data:image/png;base64,hidden-data)\n**history**\n`code`\n"
        let body = TextSearchBody.make(source, format: .markdown)
        XCTAssertTrue(body.text.contains("档案")); XCTAssertTrue(body.text.contains("图片说明")); XCTAssertTrue(body.text.contains("history")); XCTAssertFalse(body.text.contains("hidden-url")); XCTAssertFalse(body.text.contains("hidden-data")); XCTAssertFalse(body.text.contains("**"))
        var cache: [String:String] = [:]
        let hit = FolderSearchService.matches(body.page(format: .markdown, bodyOnly: true), query: "history", limit: 1, cache: &cache)[0]
        XCTAssertEqual((source as NSString).substring(with: hit.range), "history")
    }
    func testTextLineNumberAndEmojiSourceOffsetsRemainCorrect() {
        let source = "# 😀\n\n资料 [歷史](https://example.com)"
        let body = TextSearchBody.make(source, format: .markdown)
        var cache: [String:String] = [:]
        let hit = FolderSearchService.matches(body.page(format: .markdown, bodyOnly: true), query: "历史", limit: 10, cache: &cache)[0]
        XCTAssertEqual((source as NSString).substring(with: hit.range), "歷史"); XCTAssertEqual(TextSearchBody.line(at: hit.range.location, starts: body.lineStarts), 3)
    }
    func testBodyAndSourceModeUseSeparateCacheEntries() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md"); try "[visible](https://hidden-url.test)".write(to: file, atomically: true, encoding: .utf8)
        let index = root.appendingPathComponent("index.sqlite")
        let body = try FolderSearchService.run(folder: root, query: "hidden-url", recursive: true, indexURL: index, includeText: true, bodyOnly: true)
        XCTAssertTrue(body.hits.isEmpty)
        let raw = try FolderSearchService.run(folder: root, query: "hidden-url", recursive: true, indexURL: index, includeText: true, bodyOnly: false)
        XCTAssertEqual(raw.hits.count, 1); XCTAssertFalse(raw.files[0].cached)
        let again = try FolderSearchService.run(folder: root, query: "hidden-url", recursive: true, indexURL: index, includeText: true, bodyOnly: false)
        XCTAssertTrue(again.files[0].cached)
    }
    @MainActor func testLiveHTMLBodySearchSelectsSourceEntityAndRejectsChangedBuffer() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(storage: root), note = store.newNote(format: .html); note.text = "<p>😀 历<b>史</b>&amp;档案</p>"
        var cache: [String:String] = [:]
        let file = try store.searchSnapshots()[0].search(query: "历史&", limit: 10, terms: FolderSearchTerms(), includeAnnotations: true, cache: &cache)
        let hit = try XCTUnwrap(file.hits.first); XCTAssertEqual((note.text as NSString).substring(with: hit.hit.range), "历<b>史</b>&amp;")
        XCTAssertEqual(hit.textLine, 1); XCTAssertTrue(try store.openLiveSearch(hit)); note.text += "changed"; XCTAssertThrowsError(try store.openLiveSearch(hit))
    }
    func testCurrentOnlyResultLimitRemainsBounded() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let live = (0..<3).map { SearchSnapshot(id: UUID(), title: "\($0)", text: "history") }
        let result = try FolderSearchService.run(folder: nil, query: "history", recursive: true, indexURL: root.appendingPathComponent("unused.sqlite"), limit: 1, live: live)
        XCTAssertEqual(result.hits.count, 1); XCTAssertTrue(result.truncated); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused.sqlite").path))
    }
    @MainActor func testPortableNoteSaveAsCarriesSourcesImagesAndSurvivesOriginalFolderRemoval() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let original = old.appendingPathComponent("original.pdf"); let bytes = try pdf(["history"]); try bytes.write(to: original)
        let source = SourceRef(path: original.path, fileName: "original.pdf", page: 0, relativePath: "original.pdf", fingerprint: OCRPageCache.digest(bytes), anchor: "history")
        let text = "# 笔记\n\n[返回原文](\(SourceLink.url(source)!.absoluteString))\n\n![图](data:image/png;base64,\(try Release029Tests().png().base64EncodedString()))"
        let note = MarkdownNote(text: text, fileURL: old.appendingPathComponent("note.md"), storage: root.appendingPathComponent("app"))
        let destination = new.appendingPathComponent("copied.md"); try note.write(to: destination)
        try FileManager.default.removeItem(at: old)
        let reopened = try MarkdownNote.open(destination, storage: root.appendingPathComponent("app")); let ref = try link(in: reopened.text)
        XCTAssertTrue(try SourceLink.resolved(ref, baseURL: new).path.hasPrefix(new.path)); XCTAssertEqual(try reopened.renderDocument().pageCount, 1)
        XCTAssertTrue(ref.relativePath!.contains("copied-sources/")); XCTAssertTrue(reopened.text.contains("copied-assets/"))
    }
    func testSourceCarryDoesNotCopyUnreferencedFilesAndDeduplicatesReferences() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new"); try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let bytes = try pdf(["history"]), file = old.appendingPathComponent("a.pdf"); try bytes.write(to: file); try bytes.write(to: old.appendingPathComponent("unrelated.pdf"))
        let ref = SourceRef(path: file.path, fileName: "a.pdf", page: 0, relativePath: "a.pdf"), url = SourceLink.url(ref)!.absoluteString
        let result = try SourceLink.saving("[one](\(url)) [two](\(url))", oldBase: old, destination: new.appendingPathComponent("note.md"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: new.appendingPathComponent("note-sources").path).count, 1)
        XCTAssertNotNil(try link(in: result).fingerprint)
    }
    @MainActor func testMissingPortableSourceLeavesExistingNoteUnchanged() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("missing.pdf"), destination = root.appendingPathComponent("keep.md"); try "keep".write(to: destination, atomically: true, encoding: .utf8)
        let ref = SourceRef(path: original.path, fileName: "missing.pdf", page: 0, relativePath: "missing.pdf")
        let note = MarkdownNote(text: "[返回](\(SourceLink.url(ref)!.absoluteString))", fileURL: root.appendingPathComponent("old.md"), storage: root)
        XCTAssertThrowsError(try note.write(to: destination)); XCTAssertEqual(try String(contentsOf: destination), "keep"); XCTAssertEqual(note.fileURL?.lastPathComponent, "old.md")
    }
    func testSavingPortableNoteInSameFolderPreservesRelativeSourceLocation() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.pdf"); try pdf(["history"]).write(to: file)
        let ref = SourceRef(path: "/old/location.pdf", fileName: "a.pdf", page: 0, relativePath: "a.pdf")
        let result = try SourceLink.saving("[返回](\(SourceLink.url(ref)!.absoluteString))", oldBase: root, destination: root.appendingPathComponent("note.md"))
        XCTAssertEqual(try link(in: result).relativePath, "a.pdf"); XCTAssertEqual(try link(in: result).path, file.resolvingSymlinksInPath().path)
    }
    @MainActor func testEditedWordPreviewIsExportedWithoutChangingPDFOrApplyingRulesTwice() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root); workspace.document = PDFDocument(data: try pdf(["original body", "other page"]))!
        let revision = workspace.revision; try workspace.setWordDraft("第一章 修改\n\n手动 history 文字", page: 0)
        var options = workspace.wordOptions; options.content = .textOnly; options.replacements = [ReplacementRule(from: "history", to: "wrong")]
        let output = root.appendingPathComponent("edited.docx"); _ = try WordExport.write(workspace.document, pages: [0,1], outline: [], options: options, to: output)
        let xml = try WordExportTests().unzip(["-p",output.path,"word/document.xml"])
        XCTAssertTrue(xml.contains("手动 history 文字")); XCTAssertFalse(xml.contains("wrong")); XCTAssertTrue(xml.contains("other page")); XCTAssertTrue(xml.contains("Heading1"))
        XCTAssertTrue(workspace.document.page(at: 0)!.string!.contains("original body")); XCTAssertEqual(workspace.revision, revision)
    }
    @MainActor func testWordDraftRejectsChangedSourceAndCanClearOnePage() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(storage: root); workspace.document = PDFDocument(data: try pdf(["one","two"]))!
        try workspace.setWordDraft("edited one", page: 0); try workspace.setWordDraft("edited two", page: 1); workspace.clearWordDraft(page: 0)
        XCTAssertEqual(workspace.wordOptions.editedText?.count, 1); workspace.edited()
        XCTAssertThrowsError(try workspace.validateWordDraft()); XCTAssertThrowsError(try workspace.setWordDraft("bad", page: 0))
        workspace.clearWordDraft(); try workspace.validateWordDraft(); XCTAssertNil(workspace.wordOptions.editedFromRevision)
    }
    func testEditedParagraphsPreserveBlankLineBoundariesAndDoNotRunCleanup() {
        let result = WordCleanup.editedParagraphs("第一章 标题\n正文一\n继续\n\n正文二", headings: true)
        XCTAssertEqual(result.map(\.heading), [1,0,0]); XCTAssertEqual(result[1].text, "正文一\n继续")
        var options = WordExportOptions(); options.editedText = [0:"页眉\n\n手动正文"]; options.removeRunningMargins = true
        let page = WordCleanup.prepare(index: 0, label: nil, text: "old", regions: nil, options: options, margins: [WordCleanup.key("页眉", top:true)])
        XCTAssertEqual(page.paragraphs.map(\.text), ["页眉","手动正文"])
    }
    func testLegacyWordOptionsHaveNoDraftAndEmptyDraftIsAValidExplicitPage() throws {
        let data = try JSONEncoder().encode(WordExportOptions()); let options = try JSONDecoder().decode(WordExportOptions.self, from:data)
        XCTAssertNil(options.editedText); XCTAssertNil(options.editedFromRevision)
        var blank = options; blank.editedText = [0:""]
        XCTAssertTrue(WordCleanup.prepare(index:0,label:nil,text:"original",regions:nil,options:blank,margins:[]).paragraphs.isEmpty)
    }
    func pixels(side: Int) -> Data {
        var bytes = Data(repeating:255,count:side*side*4)
        bytes.withUnsafeMutableBytes { (raw:UnsafeMutableRawBufferPointer) in
            for y in 28..<95 { for x in 24..<100 where (x+y*3)%19 < 8 && (y%13)<8 {
                let k=(y*side+x)*4;raw[k]=20;raw[k+1]=30;raw[k+2]=40
            } }
        }; return bytes
    }
    func testScanTranslationEstimateRestoresKnownOffset() throws {
        let side=128, a=pixels(side:side), b=ImageCalibration.shifted(a,side:side,sampleX:-5,sampleY:3)
        let found=try ImageCalibration.estimate(a,b,side:side,maxShift:10)
        XCTAssertTrue(found.accepted);XCTAssertEqual(found.sampleX,5);XCTAssertEqual(found.sampleY,-3)
        XCTAssertEqual(ImageCalibration.shifted(b,side:side,sampleX:found.sampleX,sampleY:found.sampleY),a)
    }
    func testBlankAndUnchangedScansDoNotGetFalseCalibration() throws {
        let white=Data(repeating:255,count:128*128*4)
        XCTAssertFalse(try ImageCalibration.estimate(white,white,side:128,maxShift:10).accepted)
        let a=pixels(side:128);XCTAssertFalse(try ImageCalibration.estimate(a,a,side:128,maxShift:10).accepted)
    }
    func testManualComparisonOffsetLeavesPDFUntouchedAndCanReset() throws {
        let document=PDFDocument(data:try pdf(["history body"]))!,page=document.page(at:0)!
        let normal=try DetailedDifference.image(page,page,dimension:256)
        let shifted=try DetailedDifference.image(page,page,dimension:256,translation:CGPoint(x:6,y:0))
        XCTAssertEqual(normal.changedPixels,0);XCTAssertTrue(shifted.changedPixels>0);XCTAssertEqual(shifted.shift,CGPoint(x:6,y:0));XCTAssertEqual(shifted.side,256)
        let reset=try DetailedDifference.image(page,page,dimension:256);XCTAssertEqual(reset.changedPixels,0);XCTAssertTrue(page.string!.contains("history"))
    }
    func testInvalidCalibrationInputDoesNotCrash() throws {
        XCTAssertFalse(try ImageCalibration.estimate(Data(),Data(),side:0,maxShift:10).accepted)
        let a=pixels(side:128);XCTAssertEqual(ImageCalibration.shifted(a,side:128,sampleX:0,sampleY:0),a)
    }
}
