import Foundation
import PDFKit
import AppKit

enum ReadingDeskSection:String,CaseIterable { case excerpts = "摘录", notes = "笔记", essays = "札记", search = "全部资料", exports = "导出" }
enum ReadingNoteSource: Equatable {
    case currentPage, wholeBook, independent
}

extension Workspace {
    var readingJournalPath:String? {
        guard let path = displayPath else { return nil }
        if let cached = journalSourceIdentity,cached.raw == path { return cached.canonical }
        let canonical = ReadingProgress.canonicalPath(path); journalSourceIdentity = (path,canonical); return canonical
    }
    func readingCitation(page index:Int? = nil,rects:[CGRect] = [],anchor:String? = nil,trackVisual:Bool = true) -> ReadingCitation {
        let i = index ?? selection
        let label = store?.research.displayLabel(path:displayPath ?? "",page:i,fallback:ReadingServices.pageLabel(document.page(at:i) ?? PDFPage(),index:i) ?? String(i+1))
        var citation=ReadingCitation(source:SourceRef(path:readingJournalPath ?? "",fileName:displayName,page:max(0,i),pageLabel:label,fingerprint:fileBaseline?.digest,rects:rects,anchor:anchor),title:bibliography.title.isEmpty ? title : bibliography.title,author:bibliography.author,edition:bibliography.edition.isEmpty ? nil : bibliography.edition)
        if let path = readingJournalPath {
            let researched = store?.research.state.periodicals[path] ?? displayPath.flatMap { store?.research.state.periodicals[$0] }
            if let periodical = researched, !periodical.journal.isEmpty {
                citation.publication = ReadingPublication053(periodical:periodical.journal,
                    issue:[periodical.volume,periodical.issue].filter{!$0.isEmpty}.joined(separator:" · "),
                    published:periodical.date.isEmpty ? periodical.year : periodical.date)
            } else if let metadata = store?.library.books.first(where:{ $0.path == path })?.issueMetadata, !metadata.periodical.isEmpty {
                citation.publication = ReadingPublication053(periodical:metadata.periodical,
                    issue:[metadata.volume,metadata.issue].filter{!$0.isEmpty}.joined(separator:" · "),published:metadata.year)
            }
            let identity = ReadingDocumentRegistry053.shared(storage).identity(path,digest:fileBaseline?.digest)
            citation.tracking = ReadingSourceIdentity053(documentID:identity.id,capturedPage:max(0,i),
                pageFingerprint:pageIdentity053(max(0,i)),capturedPageLabel:label,
                visualFingerprint:trackVisual ? document.page(at:i).flatMap(ReadingSourceRecovery.fingerprint) : nil)
        }
        return citation
    }
    func captureReadingExcerpt(_ selection:PDFSelection) -> Bool {
        guard let store, store.readingMode else { return false }
        guard !store.journal.unreadable else { error = store.journal.error; return true }
        guard let record = readingExcerpt(from:selection) else { error = "请选中文字；扫描页可使用图片摘录"; return true }
        store.saveReadingExcerpt(record)
        status = store.readingExcerptFeedback?.message ?? "摘录已加入阅读记录"
        return true
    }

    func readingExcerpt(from selection: PDFSelection,trackVisual:Bool = true) -> ReadingRecord? {
        guard let raw = selection.string else { return nil }
        let quote = ExcerptText.tidy(raw)
        guard !quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
        let selectedLines = selection.selectionsByLine()
        let citations = selection.pages.compactMap { page -> ReadingCitation? in
            let index = document.index(for:page); guard index != NSNotFound else { return nil }
            let lines = selectedLines.filter { $0.pages.contains(where:{$0 === page}) }
            let rectangles = (lines.isEmpty ? [selection] : lines).map { $0.bounds(for:page) }.filter { !$0.isEmpty }
            return readingCitation(page:index,rects:rectangles,anchor:String((page.string?.contains(raw) == true ? raw : lines.first?.string ?? "").prefix(40)),trackVisual:trackVisual)
        }
        guard !citations.isEmpty else { return nil }
        return ReadingRecord(kind:.excerpt,quote:quote,citations:citations)
    }
}
extension WorkspaceStore {
    func openNoteLibrary() { readingLibraryPreferredKind = "笔记";readingLibraryNavigation = nil;readingLibraryNavigationRequest = UUID();openReadingDesk(.search,window:true) }
    func showReadingPanel(_ section:ReadingDeskSection, noteID: UUID? = nil) {
        let returningToNotes = section == .notes && (!showReadingDesk || readingDeskSection != .notes)
        if section != .notes { rememberRightPanelNote() }
        if let noteID { readingRecordID = noteID }
        else if returningToNotes, let last = journal.record(lastRightPanelNoteID), last.kind == .note, last.removed == nil {
            readingRecordID = last.id
        }
        lastRightPanelWasSearch = false
        pdfSearchWorkspaceID = nil
        readingMode = true
        readingDeskSection = section
        showReadingDesk = true
    }
    func openReadingDesk(_ section:ReadingDeskSection,window:Bool = false) {
        if window || section == .essays || section == .exports {
            readingDeskWindowSection = section
            readingDeskWindowRequest = UUID()
        } else { showReadingPanel(section) }
    }
    var currentNoteSourceWorkspace: Workspace? {
        guard let workspace = commandWorkspace, workspace.count > 0, !workspace.busy,
              workspace.readingJournalPath != nil else { return nil }
        return workspace
    }

    func newReadingNote(source: ReadingNoteSource = .currentPage, linked: ReadingRecord? = nil) {
        guard let draft = prepareReadingNote(source:source,linked:linked) else { return }
        showReadingPanel(.notes,noteID:draft.id)
    }

    func prepareReadingNote(source: ReadingNoteSource = .currentPage, linked: ReadingRecord? = nil) -> ReadingRecord? {
        guard !journal.unreadable else { present(FolioError(message:journal.error ?? "阅读记录未能读取")); return nil }
        let citation = source == .independent || linked != nil ? nil : currentNoteSourceWorkspace?.readingCitation()
        let refs = linked?.citations053 ?? citation.map { [$0] } ?? []
        let record = ReadingRecord(kind:.note,quote:linked.map{$0.quote.isEmpty ? ($0.pdfOrigin?.contents ?? "") : $0.quote} ?? "",
                                   note:linked?.excerptRemark ?? "",citations:refs,linkedRecords:linked.flatMap { journal.record($0.id) != nil ? [$0.id]:nil } ?? [],
                                   wholeBook:linked?.wholeBook ?? (source == .wholeBook && !refs.isEmpty))
        pinnedReadingID = nil
        journal.beginNote(record)
        readingRecordID = record.id
        return record
    }

    func changeNoteSource(_ id: UUID, to source: ReadingNoteSource) {
        guard let record = journal.record(id), record.canChangeNoteSource else { return }
        let citation = source == .independent ? nil : (record.citations.first ?? currentNoteSourceWorkspace?.readingCitation())
        guard source == .independent || citation != nil else { return }
        let citations = citation.map { [$0] } ?? []
        let wholeBook = source == .wholeBook
        guard record.citations != citations || record.wholeBook != wholeBook else { return }
        let isDraft = journal.draftRecord?.id == id
        journal.editRecord(id) {
            if isDraft && $0.wholeBook && $0.title == "整本书心得" { $0.title = "" }
            $0.citations = citations
            $0.wholeBook = wholeBook
        }
    }

    @discardableResult
    func addCurrentPageToNote(_ id: UUID) -> Bool {
        guard !journal.unreadable, let record = journal.record(id), record.kind == .note,
              record.removed == nil, let workspace = currentNoteSourceWorkspace else { return false }
        let citation = workspace.readingCitation()
        let book = ReadingBookIdentity.key(citation.source.path)
        let alreadyAdded = record.citations053.contains { existing in
            let sameDocument = citation.tracking.map { existing.tracking?.documentID == $0.documentID } ?? false
            return existing.source.page == citation.source.page &&
                (ReadingBookIdentity.key(existing.source.path) == book || sameDocument)
        }
        guard !alreadyAdded || record.wholeBook else { return false }
        let isDraft = journal.draftRecord?.id == id
        journal.editRecord(id) {
            if $0.wholeBook && $0.title == "整本书心得" && isDraft { $0.title = "" }
            $0.wholeBook = false
            if !alreadyAdded { $0.citations.append(citation) }
        }
        return true
    }
    func importLegacyReadingRecords() async {
        await journal.importLegacy(cards:board.cards,books:library.books+(library.catalog.pendingBooks ?? []),topics:research.state.topics ?? [],annotations:research.state.annotations)
    }
    func restoreReadingRecord(for workspace:Workspace) {
        guard workspace.id != stagedShelfTab || workspace.id == selectedID,
              readingMode, let path = workspace.readingJournalPath, let id = journal.state.lastNotes[path],
              let record = journal.record(id), record.removed == nil, record.hasContent,
              ReadingLibraryItem.record(record).isFromBook(path) else { return }
        if showReadingDesk && readingDeskSection == .excerpts { return }
        if showReadingDesk, readingDeskSection == .notes,
           let current = journal.record(pinnedReadingID ?? readingRecordID),
           current.kind == .note, current.removed == nil { return }
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


struct BookSearchRequest: Equatable {
    let id = UUID()
    let section: ReadingDeskSection
}

extension WorkspaceStore {
    func searchCurrentBook(_ section:ReadingDeskSection) {
        showReadingPanel(section)
        bookSearchRequest = BookSearchRequest(section:section)
    }
}
