import AppKit
import PDFKit
import UniformTypeIdentifiers

enum FileEditingTool:String,CaseIterable,Identifiable {
    case paragraphs = "段落与章节整理",table = "可视化表格",images = "图片与图题",footnotes = "解释性脚注",history = "版本差异与局部恢复",merge = "外部修改比较与合并",corrections = "校勘与存疑记录",encoding = "编码预览与转换副本",characters = "不可见字符检查"
    var id:String { rawValue }
}
extension MarkdownNote {
    func toggleReadOnly() {
        guard textView?.hasMarkedText() != true,(NSApp?.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { status = "请先完成正在输入的文字，再切换模式";return }
        readOnly.toggle();textView?.isEditable = !readOnly;status = readOnly ? "阅读模式：正文已保护" : "编辑模式"
    }
    @discardableResult func commitEditorEdit(_ edit:TextEdit,expected:String) -> Bool {
        guard !readOnly,let view = textView,view.isEditable,!view.hasMarkedText(),text == expected,view.string == expected else { error = "正文已变化、正在输入或处于阅读模式。请完成输入后重新打开此工具";return false }
        apply(edit);return true
    }
    func createEditingCopy(text override:String? = nil,baseURL overrideBase:URL? = nil,format overrideFormat:TextDocumentFormat? = nil) {
        guard textView?.hasMarkedText() != true,(NSApp?.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { status = "请先完成正在输入的文字";return }
        let copyFormat = overrideFormat ?? format
        let panel = NSSavePanel();panel.allowedContentTypes = [UTType(filenameExtension:copyFormat.fileExtension) ?? .plainText];panel.nameFieldStringValue = title+"-编辑副本."+copyFormat.fileExtension
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try writeEditingCopy(to:url,text:override,baseURL:overrideBase,format:overrideFormat);store?.openNote(url);status = "已创建独立副本；原文保留" } catch { recordError(error) }
    }
    func writeEditingCopy(to url:URL,text override:String? = nil,baseURL overrideBase:URL? = nil,format overrideFormat:TextDocumentFormat? = nil) throws {
        let expected = try FileBaseline.capture(url)
        guard !FileManager.default.fileExists(atPath:url.path),url.standardizedFileURL != fileURL?.standardizedFileURL else { throw FolioError(message:"编辑副本需要使用一个新的文件名，以保留现有文件") }
        let base = overrideBase ?? fileURL?.deletingLastPathComponent() ?? recoveryBaseURL
        let linked = try SourceLink.saving(override ?? text,oldBase:base,destination:url)
        let prepared = try TextAssets.saving(linked,format:overrideFormat ?? format,oldBase:base,destination:url)
        _ = try expected.writing(url) { try prepared.write(to:$0,atomically:true,encoding:.utf8) }
    }
    func preserveBeforeTool(_ label:String) throws {
        try writeBackup()
        if let fileURL { try TextVersionHistory.record(versionSnapshot,source:fileURL,storage:storage,label:label) }
    }
    func followSourceSelection() {
        previewFollowTask?.cancel()
        guard followPreview,let view = textView,!view.hasMarkedText() else { return }
        let ns = view.string as NSString,range = ns.paragraphRange(for:MarkdownNote.clamp(view.selectedRange(),to:ns.length))
        guard range != lastFollowedParagraph || previewView?.document !== lastFollowedDocument else { return }
        previewFollowTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:350_000_000) } catch { return }
            guard let self,!Task.isCancelled,self.followPreview,self.textView?.hasMarkedText() != true else { return }
            self.lastFollowedParagraph = range;self.lastFollowedDocument = self.previewView?.document;self.locatePreview(focus:false)
        }
    }
    func locatePreview(focus:Bool = false) {
        guard let sourceView = textView,let previewView,let document = previewView.document,!sourceView.hasMarkedText() else { return }
        let ns = sourceView.string as NSString,r = EditorNavigation.scope(sourceView.string,selection:sourceView.selectedRange(),explicit:focus)
        var query = ns.substring(with:r).trimmingCharacters(in:.whitespacesAndNewlines)
        if format == .markdown { query = query.replacingOccurrences(of:#"^[#>\s*-]+"#,with:"",options:.regularExpression).replacingOccurrences(of:"**",with:"") }
        if format == .html { query = TextTableEntities.decode(query.replacingOccurrences(of:#"<[^>]+>"#,with:"",options:.regularExpression)) }
        guard !query.isEmpty else { return };query = String(query.prefix(100))
        let hits:[PDFSelection]
        if focus { hits = document.findString(query,withOptions:.caseInsensitive) }
        else {
            let current = max(0,min(max(0,document.pageCount-1),previewView.currentPage.map{document.index(for:$0)} ?? 0))
            let estimated = min(max(0,document.pageCount-1),Int(Double(r.location)/Double(max(1,ns.length))*Double(document.pageCount)))
            let pages = Set((max(0,current-2)...min(max(0,document.pageCount-1),current+2)).map{$0}+(max(0,estimated-3)...min(max(0,document.pageCount-1),estimated+3)).map{$0})
            hits = pages.sorted().compactMap { index in
                guard let page = document.page(at:index),let text = page.string else { return nil }
                let hit = (text as NSString).range(of:query,options:.caseInsensitive)
                return hit.location == NSNotFound ? nil : page.selection(for:hit)
            }
        }
        let currentPage = previewView.currentPage.map { document.index(for:$0) } ?? 0
        func distance(_ selection:PDFSelection)->Int { guard let page = selection.pages.first else { return Int.max };return abs(document.index(for:page)-currentPage) }
        guard let hit = hits.min(by:{ distance($0) < distance($1) }) else { if focus { status = "此段暂未在预览中找到；可选取较短的正文文字再定位" };return }
        previewView.go(to:hit)
        if focus { status = "已定位预览中的当前段落" }
    }
    func locateSource(focus:Bool) {
        guard let value = previewView?.currentSelection?.string?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,let view = textView,!view.hasMarkedText() else { if focus { status = "请先在预览里选中一段文字" };return }
        let query = String(value.prefix(150)),ns = text as NSString;var matches:[NSRange] = [],p = 0
        while p < ns.length && matches.count < 2000 { let hit = ns.range(of:query,options:.caseInsensitive,range:NSRange(location:p,length:ns.length-p));if hit.location == NSNotFound { break };matches.append(hit);p = NSMaxRange(hit) }
        guard let range = matches.min(by:{abs($0.location-view.selectedRange().location)<abs($1.location-view.selectedRange().location)}) else { if focus { status = "选中文字含排版换行，请选取较短文字再定位" };return }
        view.scrollRangeToVisible(range)
        if focus { view.setSelectedRange(range);view.window?.makeFirstResponder(view);status = "已返回正文位置" }
    }
    var textForExport:String { EditorCorrections.export(text,include:includeCorrections,html:format == .html) }
}
extension Workspace {
    func toggleReadingLock() {
        guard !drawingInProgress,placingSignature == nil,!busy else { status = "请先完成当前操作";return }
        readingLocked.toggle();tool = .select;selectedAnnotation = nil;showAnnotationBar = false;pdfView?.clearSelection();status = readingLocked ? "阅读模式：标注已保护，可继续摘录和记笔记" : "编辑模式：可以修改 PDF 标注"
    }
    func createEditingCopy() {
        guard !busy,!drawingInProgress,placingSignature == nil else { status = "请先完成当前操作";return }
        let panel = NSSavePanel();panel.allowedContentTypes = [.pdf];panel.nameFieldStringValue = title+"-编辑副本.pdf"
        guard panel.runModal() == .OK,let target = panel.url else { return }
        do {
            let expected = try FileBaseline.capture(target)
            guard !FileManager.default.fileExists(atPath:target.path) else { throw FolioError(message:"请为编辑副本使用新的文件名") }
            var archive = try snapshot();archive.sourcePath = target.path;archive.projectPath = nil;archive.dirty = false
            _ = try expected.writing(target) { try archive.pdf.write(to:$0,options:.atomic) }
            try ReadingDocumentStore.write(archive,source:target,storage:storage)
            try SignaturePersistence.write(archive.signatureEdits ?? [:],pdf:target,storage:storage)
            store?.openInNewTab([target]);status = "已建立独立 PDF 编辑副本"
        } catch { recordError(error) }
    }
}
