import AppKit
import PDFKit

enum ReadingNoteCitationInsertion {
    static func markdown(_ excerpt:ReadingRecord) -> String {
        let quote = excerpt.quote.components(separatedBy:.newlines).map{"> "+ReadingRecordExport.literal($0)}.joined(separator:"\n")
        let sources = excerpt.citations.map { citation in
            let label = ReadingRecordExport.literal(ReadingExportOrdering.citation(citation))
            let link = SourceLink.url(citation.source).map{" [返回原文](<"+$0.absoluteString+">)"} ?? ""
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
            for citation in excerpt.citations where !record.citations.contains(citation) { record.citations.append(citation) }
            record.wholeBook = false
        }
        workspace.status = "已将所选原文与出处插入笔记"
        return true
    }
}
