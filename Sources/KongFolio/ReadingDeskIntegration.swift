import Foundation
import PDFKit
import AppKit

enum ReadingDeskSection:String,CaseIterable { case excerpts = "摘录", notes = "笔记", essays = "札记", search = "全部资料", exports = "导出" }
extension Workspace {
    var readingJournalPath:String? {
        guard let path = displayPath else { return nil }
        if let cached = journalSourceIdentity,cached.raw == path { return cached.canonical }
        let canonical = ReadingProgress.canonicalPath(path); journalSourceIdentity = (path,canonical); return canonical
    }
    func readingCitation(page index:Int? = nil,rects:[CGRect] = [],anchor:String? = nil) -> ReadingCitation {
        let i = index ?? selection
        let label = store?.research.displayLabel(path:displayPath ?? "",page:i,fallback:ReadingServices.pageLabel(document.page(at:i) ?? PDFPage(),index:i) ?? String(i+1))
        var citation=ReadingCitation(source:SourceRef(path:readingJournalPath ?? "",fileName:displayName,page:max(0,i),pageLabel:label,fingerprint:fileBaseline?.digest,rects:rects,anchor:anchor),title:bibliography.title.isEmpty ? title : bibliography.title,author:bibliography.author,edition:bibliography.edition.isEmpty ? nil : bibliography.edition)
        if let path=readingJournalPath { let identity=ReadingDocumentRegistry053.shared(storage).identity(path,digest:fileBaseline?.digest);citation.tracking=ReadingSourceIdentity053(documentID:identity.id,capturedPage:max(0,i),pageFingerprint:pageIdentity053(max(0,i)),capturedPageLabel:label) }
        return citation
    }
    func captureReadingExcerpt(_ selection:PDFSelection) -> Bool {
        guard let store, store.readingMode else { return false }
        guard !store.journal.unreadable else { error = store.journal.error; return true }
        guard let raw = selection.string, !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { error = "请选中文字；扫描页可使用图片摘录"; return true }
        let citations = selection.pages.compactMap { page -> ReadingCitation? in
            let index = document.index(for:page); guard index != NSNotFound else { return nil }
            let lines = selection.selectionsByLine().filter { $0.pages.contains(where:{$0 === page}) }
            return readingCitation(page:index,rects:lines.map{$0.bounds(for:page)},anchor:String((page.string?.contains(raw) == true ? raw : lines.first?.string ?? "").prefix(40)))
        }
        let record = ReadingRecord(kind:.excerpt,quote:ExcerptText.tidy(raw),citations:citations)
        store.journal.add(record); store.readingRecordID = record.id; store.openReadingDesk(.excerpts); status = "摘录已加入阅读记录，原文未改动"; return true
    }
}
extension WorkspaceStore {
    func openNoteLibrary() { readingLibraryPreferredKind = "笔记";readingLibraryNavigation = nil;readingLibraryNavigationRequest = UUID();openReadingDesk(.search,window:true) }
    func showReadingPanel(_ section:ReadingDeskSection) { readingMode = true;readingDeskSection = section;showReadingDesk = true }
    func openReadingDesk(_ section:ReadingDeskSection,window:Bool = false) {
        readingDeskSection = section
        if window || section == .essays || section == .exports || (NSApp?.keyWindow?.frame.width ?? 1000) < 850 || (activeWorkspace != nil && !readingMode) { readingDeskWindowRequest = UUID() }
        else { showReadingPanel(section) }
    }
    func newReadingNote(bookWide:Bool = false,linked:ReadingRecord? = nil) {
        guard !journal.unreadable else { present(FolioError(message:journal.error ?? "阅读记录未能读取")); return }
        let citation = commandWorkspace.flatMap { $0.count > 0 ? $0.readingCitation() : nil }
        let refs = linked?.citations ?? citation.map { [$0] } ?? []
        let record = ReadingRecord(kind:.note,title:bookWide ? "整本书心得" : "",quote:linked.map{$0.quote.isEmpty ? ($0.pdfOrigin?.contents ?? "") : $0.quote} ?? "",citations:refs,linkedRecords:linked.flatMap { journal.record($0.id) != nil ? [$0.id]:nil } ?? [],wholeBook:bookWide)
        pinnedReadingID = nil; journal.beginNote(record); readingRecordID = record.id; openReadingDesk(.notes)
    }
    func importLegacyReadingRecords() async {
        await journal.importLegacy(cards:board.cards,books:library.books+(library.catalog.pendingBooks ?? []),topics:research.state.topics ?? [],annotations:research.state.annotations)
    }
    func restoreReadingRecord(for workspace:Workspace) {
        guard readingMode, let path = workspace.readingJournalPath, let id = journal.state.lastNotes[path], let record = journal.record(id), record.removed == nil, record.hasContent else { return }
        readingRecordID = id; readingDeskSection = record.kind == .note ? .notes : .excerpts
    }
    func newReadingEssay() { _ = journal.newEssay(); openReadingDesk(.essays,window:true) }
}

extension WorkspaceStore {
    func insertReadingRecord(_ record:ReadingRecord,in essay:UUID) {
        let key = readingEssayBlockID.map{"essay:"+essay.uuidString+":"+$0.uuidString} ?? ""
        readingEssayBlockID = journal.insert(record,in:essay,after:readingEssayBlockID,at:WritingRegistry.selection(key))
    }
}
