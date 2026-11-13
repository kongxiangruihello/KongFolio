import AppKit

enum ReadingTriage: String, Codable, CaseIterable {
    case verify = "待核对"
    case write = "待写笔记"
}

struct ReadingFollowUp: Codable, Equatable, Identifiable {
    var id = UUID()
    let question: String
    let passage: String
    let offset: Int
    let block: UUID?
    var resolved: Date?

    static func capture(question: String, text: String, selection: NSRange, block: UUID?) -> Self? {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = text as NSString
        guard !question.isEmpty, content.length > 0 else { return nil }
        let caret = max(0,min(selection.location,content.length - 1))
        let range = selection.length > 0 ? MarkdownNote.clamp(selection,to:content.length) :
            content.lineRange(for:NSRange(location:caret,length:0))
        let passage = String(content.substring(with:range).trimmingCharacters(in:.whitespacesAndNewlines).prefix(300))
        guard !passage.isEmpty else { return nil }
        let start = content.range(of:passage,options:.literal,range:range)
        guard start.location != NSNotFound else { return nil }
        return Self(question:question,passage:passage,offset:start.location,block:block)
    }

    func locate(in text: String) -> NSRange? {
        let body = text as NSString
        let length = passage.utf16.count
        guard length > 0 else { return nil }
        let original = NSRange(location:offset,length:length)
        if offset >= 0, offset <= body.length, length <= body.length-offset,
           body.substring(with:original) == passage { return original }
        let match = body.range(of:passage,options:.literal)
        guard match.location != NSNotFound else { return nil }
        let end = NSMaxRange(match)
        let rest = body.range(of:passage,options:.literal,range:NSRange(location:end,length:body.length-end))
        return rest.location == NSNotFound ? match : nil
    }
}

struct ReadingCitationClipboardOptions: Codable, Equatable {
    var printedPage = true
    var sourceLink = false
    private static let key = "KongFolio.citationClipboardOptions"

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey:key).flatMap { try? JSONDecoder().decode(Self.self,from:$0) } ?? Self()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data,forKey:Self.key) }
    }

    func text(_ records: [ReadingRecord]) -> String {
        records.flatMap { record -> [String] in
            if record.excerptSegments != nil {
                return record.textExcerptSegments.map { format($0.text,citations:$0.sources(in:record)) }
            }
            let text = record.quote.isEmpty ? (record.pdfOrigin?.contents ?? (record.imageAsset == nil ? "" : "[图片摘录]")) : record.quote
            return [format(text,citations:record.citations053)]
        }.filter { !$0.isEmpty }.joined(separator:"\n\n")
    }

    private func format(_ text: String, citations: [ReadingCitation]) -> String {
        let sources = citations.map { citation -> String in
            var value = citation
            if !printedPage { value.source.pageLabel = nil }
            let label = ReadingExportOrdering.citation(value)
            if sourceLink, value.source.invalidPage053 != true, let url = SourceLink.url(value.source) {
                return label+"\n"+url.absoluteString
            }
            return label
        }
        return ([text]+sources).filter { !$0.isEmpty }.joined(separator:"\n")
    }
}

struct ReadingDetailRequest: Equatable {
    enum Target: Equatable { case quotation(UUID), block(UUID), linkedQuote }
    var item: ReadingLibraryID
    var target: Target
}

extension ReadingRecord {
    var isExcerpt: Bool { kind == .excerpt || kind == .image }

    var frozenExcerptParts: [ReadingQuotation053] {
        var original = ReadingWorkflow053.frozen(.record(self))
        original.text = quote
        original.excerptOnly = true
        let segments = textExcerptSegments
        guard !segments.isEmpty else { return [original] }
        return segments.map { segment in
            var quote = original
            quote.id = UUID()
            quote.text = segment.text
            quote.citations = segment.sources(in:self)
            quote.captured = segment.captured
            quote.originalCreated = segment.captured
            quote.excerptSegmentID = segment.id
            return quote
        }
    }
}

extension ReadingJournal {
    @discardableResult func appendExcerpt(_ source: UUID,toNote noteID: UUID) -> Int {
        guard !unreadable, let source = record(source), source.isExcerpt, source.removed == nil,
              let target = record(noteID), target.kind == .note, target.removed == nil else { return 0 }
        let existing = target.extras?.quotations ?? []
        let additions = source.frozenExcerptParts.filter { part in
            !existing.contains { $0.recordID == part.recordID && $0.excerptSegmentID == part.excerptSegmentID }
        }
        guard !additions.isEmpty else { return 0 }
        editRecord(noteID) { note in
            var extras = note.extras ?? ReadingRecordExtras053()
            extras.quotations = existing+additions
            note.extras = extras
        }
        return additions.count
    }

    func makeTopicNote(title: String, excerpts: [UUID]) throws -> UUID {
        let title = title.trimmingCharacters(in:.whitespacesAndNewlines)
        var seen = Set<UUID>()
        let ids = excerpts.filter { seen.insert($0).inserted }
        let records = ids.compactMap { record($0) }
        guard !unreadable, !title.isEmpty, !ids.isEmpty, records.count == ids.count,
              records.allSatisfy({ $0.isExcerpt && $0.removed == nil && $0.hasContent }) else {
            throw FolioError(message:"请确认标题和选中的摘录仍可用")
        }
        let essay = ReadingEssay(title:title,blocks:records.map { ReadingEssay.Block(record:$0) })
        change { state in state.essays.append(essay); state.currentEssay = essay.id }
        return essay.id
    }

    func setExcerptVersions(_ left: UUID, _ right: UUID, linked: Bool) throws {
        guard !unreadable, left != right,
              let a = state.records.firstIndex(where:{$0.id == left && $0.isExcerpt && $0.removed == nil}),
              let b = state.records.firstIndex(where:{$0.id == right && $0.isExcerpt && $0.removed == nil}) else {
            throw FolioError(message:"请选择两条仍在资料库中的摘录")
        }
        change { state in
            for (index,other) in [(a,right),(b,left)] {
                var extras = state.records[index].extras ?? ReadingRecordExtras053()
                var values = extras.versionExcerpts ?? []
                values.removeAll { $0 == other }
                if linked { values.append(other) }
                extras.versionExcerpts = values.isEmpty ? nil : values
                state.records[index].extras = extras
                state.records[index].modified = Date()
            }
        }
    }

    func saveFollowUp(_ question: ReadingFollowUp, in item: ReadingLibraryID) {
        guard libraryItem053(item) != nil else { return }
        updateExtras053([item]) { extras in
            var values = extras.followUps ?? []
            if let index = values.firstIndex(where:{$0.id == question.id}) { values[index] = question }
            else { values.append(question) }
            extras.followUps = values
        }
    }
}

extension WorkspaceStore {
    var pinnedExcerptNote: ReadingRecord? {
        guard let note = journal.record(pinnedReadingID), note.kind == .note, note.removed == nil else { return nil }
        return note
    }

    func openFollowUp(_ item:ReadingLibraryItem, question:ReadingFollowUp) -> Bool {
        let text: String
        let identity: String
        switch item {
        case .record(let record):
            text = record.note
            identity = "note:"+record.id.uuidString
        case .essay(let essay):
            guard let block = essay.blocks.first(where:{$0.id == question.block}) else {
                writingSearchHit = nil
                openReadingItem(item.id)
                return false
            }
            text = block.text
            identity = "essay:"+essay.id.uuidString+":"+block.id.uuidString
        }
        let match = question.locate(in:text)
        writingSearchHit = match.map { ReadingTextHit(identity:identity,range:$0,context:question.passage,source:text) }
        writingSearchRequest = UUID()
        openReadingItem(item.id)
        return match != nil
    }

    func startNoteFromExcerpt(_ excerpt: ReadingRecord) {
        guard !journal.unreadable, excerpt.isExcerpt, excerpt.removed == nil else { return }
        let draft = ReadingRecord(kind:.note,extras:ReadingRecordExtras053(quotations:excerpt.frozenExcerptParts))
        pinnedReadingID = nil
        journal.beginNote(draft)
        showReadingPanel(.notes,noteID:draft.id)
        quickExcerptNoteID = draft.id
    }

    func returnFromExcerptNote(_ id: UUID) {
        guard quickExcerptNoteID == id, let view = commandWorkspace?.pdfView, let window = view.window else { return }
        quickExcerptNoteID = nil
        if journal.draftRecord?.id == id, journal.draftRecord?.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == true {
            journal.discardNoteDraft()
            if readingRecordID == id { readingRecordID = nil }
            if lastRightPanelNoteID == id { lastRightPanelNoteID = nil }
        }
        window.makeFirstResponder(view)
    }
}

enum ReadingExcerptCopyFormat: String, CaseIterable {
    case text = "仅复制原文"
    case citation = "原文与出处"
    case markdown = "Markdown 引用"
    private static let key = "KongFolio.excerptCopyFormat"

    static func preferred(_ defaults:UserDefaults = .standard) -> Self {
        defaults.string(forKey:key).flatMap(Self.init(rawValue:)) ?? .citation
    }

    func text(_ record:ReadingRecord) -> String {
        let quote = record.quote.isEmpty ? (record.imageAsset == nil ? (record.pdfOrigin?.contents ?? "") : "[图片摘录]") : record.quote
        switch self {
        case .text: return quote
        case .citation: return ReadingCitationClipboardOptions(printedPage:true,sourceLink:false).text([record])
        case .markdown:
            if record.excerptSegments != nil {
                return record.textExcerptSegments.map { segment in
                    ReadingNoteCitationInsertion.markdown(ReadingRecord(kind:.excerpt,quote:segment.text,citations:segment.sources(in:record)))
                }.joined().trimmingCharacters(in:.newlines)
            }
            var copy = record
            copy.quote = quote
            copy.citations = record.citations053
            return ReadingNoteCitationInsertion.markdown(copy).trimmingCharacters(in:.newlines)
        }
    }

    @MainActor func copy(_ record:ReadingRecord,defaults:UserDefaults = .standard) {
        let value = text(record)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(value,forType:.string) { defaults.set(rawValue,forKey:Self.key) }
    }
}
