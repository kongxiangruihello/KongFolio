import AppKit
import PDFKit

enum ReadingNoteCitationInsertion {
    static func markdown(_ excerpt:ReadingRecord) -> String {
        let quote = excerpt.quote.components(separatedBy:.newlines).map{"> "+ReadingRecordExport.literal($0)}.joined(separator:"\n")
        let sources = excerpt.citations.map { citation in
            let label = ReadingRecordExport.literal(ReadingExportOrdering.citation(citation))
            let link = (citation.source.invalidPage053 == true ? nil : SourceLink.url(citation.source)).map{" [返回原文](<"+$0.absoluteString+">)"} ?? ""
            return "> "+label+link
        }.joined(separator:"\n")
        return "\n\n"+quote+"\n>\n"+sources+"\n\n"
    }
}

extension WorkspaceStore {
    var canInsertPDFSelectionInNote: Bool {
        showReadingDesk && readingDeskSection == .notes && pinnedExcerptNote != nil && !journal.unreadable
    }

    @discardableResult
    func insertPDFSelectionInNote(from workspace:Workspace,selection:PDFSelection) -> Bool {
        guard canInsertPDFSelectionInNote,let note = pinnedExcerptNote,
              let excerpt = workspace.readingExcerpt(from:selection) else { return false }
        let identity = "note:"+note.id.uuidString
        let text = ReadingNoteCitationInsertion.markdown(excerpt)
        guard WritingRegistry.insertAtCursor(text,key:identity,expected:note.note,window:workspace.pdfView?.window) else {
            workspace.status = "请先结束正在输入的文字，并在右侧已固定的笔记中定位光标"
            return false
        }
        journal.editRecord(note.id) { record in
            record.registerInlineNoteCitations(excerpt.citations)
        }
        workspace.status = "已将所选原文与出处插入笔记"
        return true
    }
}

struct InlineNoteCitation: Codable, Equatable {
    let link: String
    var citation: ReadingCitation
}

extension ReadingRecord {
    mutating func registerInlineNoteCitations(_ inserted:[ReadingCitation]) {
        var tracked = inlineNoteCitations ?? []
        for citation in inserted {
            guard let link = SourceLink.url(citation.source)?.absoluteString,
                  !tracked.contains(where:{$0.link == link}),
                  isInlineNoteCitation(citation) || !citations.contains(where:{Self.sameInlineSource($0,citation)}) else { continue }
            tracked.append(InlineNoteCitation(link:link,citation:citation))
        }
        inlineNoteCitations = tracked.isEmpty ? nil : tracked
        syncInlineNoteCitations()
    }

    mutating func syncInlineNoteCitations() {
        guard kind == .note, let tracked = inlineNoteCitations, !tracked.isEmpty else { return }
        let active = tracked.filter { entry in
            note.contains("(<"+entry.link+">)") || note.contains("("+entry.link+")")
        }
        let activeSources = Set(active.map{InlineSource($0.citation)})
        let trackedSources = Set(tracked.map{InlineSource($0.citation)})
        var existing = Set(citations.map(InlineSource.init))
        for entry in active where existing.insert(InlineSource(entry.citation)).inserted {
            citations.append(entry.citation)
        }
        citations.removeAll { citation in
            let key = InlineSource(citation)
            return trackedSources.contains(key) && !activeSources.contains(key)
        }
    }

    mutating func replaceInlineCitation(_ original:ReadingCitation,with updated:ReadingCitation) {
        guard let entries = inlineNoteCitations else { return }
        inlineNoteCitations = entries.map { entry in
            guard Self.sameInlineSource(entry.citation,original) else { return entry }
            return InlineNoteCitation(link:entry.link,citation:updated)
        }
    }

    func isInlineNoteCitation(_ citation:ReadingCitation) -> Bool {
        inlineNoteCitations?.contains{Self.sameInlineSource($0.citation,citation)} == true
    }

    private static func sameInlineSource(_ a:ReadingCitation,_ b:ReadingCitation) -> Bool {
        InlineSource(a) == InlineSource(b)
    }

    private struct InlineSource: Hashable {
        let path:String
        let page:Int
        let rectangles:[[CGFloat]]
        let anchor:String?

        init(_ citation:ReadingCitation) {
            let source = citation.source
            path = ReadingBookIdentity.key(source.path)
            page = source.page
            rectangles = source.rects.map{[$0.minX,$0.minY,$0.width,$0.height]}
            anchor = source.anchor
        }
    }
}
