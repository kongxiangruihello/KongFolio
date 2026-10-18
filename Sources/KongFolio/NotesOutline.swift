import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The annotations of a book arranged under its table of contents, so a reader gets what they marked chapter by chapter
/// (the "notes outline" of reading tools), with page numbers to find each one again.
struct NotesSection: Equatable {
    var title: String
    var depth: Int
    var notes: [AnnotationNote]

    static func == (lhs: NotesSection, rhs: NotesSection) -> Bool {
        lhs.title == rhs.title && lhs.depth == rhs.depth && lhs.notes.map(\.id) == rhs.notes.map(\.id)
    }
}

enum NotesOutline {
    static let beforeContents = "（目录之前）"
    static let everything = "全部标注"

    /// Sections in book order. A chapter that has notes is preceded by the headings above it, so the nesting reads right;
    /// chapters without notes are left out. With no table of contents there is one section.
    static func sections(notes: [AnnotationNote], outline: [OutlineEntry]) -> [NotesSection] {
        let ordered = notes.sorted { ($0.page, $0.index) < ($1.page, $1.index) }
        guard !ordered.isEmpty else { return [] }
        let entries = outline.enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
        guard !entries.isEmpty else { return [NotesSection(title: everything, depth: 0, notes: ordered)] }
        var grouped: [Int: [AnnotationNote]] = [:]
        var before: [AnnotationNote] = []
        for note in ordered {
            if let index = entries.lastIndex(where: { $0.page <= note.page }) { grouped[index, default: []].append(note) } else { before.append(note) }
        }
        var result: [NotesSection] = []
        if !before.isEmpty { result.append(NotesSection(title: beforeContents, depth: 0, notes: before)) }
        var emitted = Set<Int>()
        for index in entries.indices {
            guard let own = grouped[index] else { continue }
            // The nearest earlier entry at each shallower level.
            var ancestors: [Int] = []
            var level = entries[index].depth
            var cursor = index - 1
            while cursor >= 0, level > 0 {
                if entries[cursor].depth < level { ancestors.insert(cursor, at: 0); level = entries[cursor].depth }
                cursor -= 1
            }
            for ancestor in ancestors where !emitted.contains(ancestor) && grouped[ancestor] == nil {
                result.append(NotesSection(title: entries[ancestor].label, depth: entries[ancestor].depth, notes: []))
                emitted.insert(ancestor)
            }
            emitted.insert(index)
            result.append(NotesSection(title: entries[index].label, depth: entries[index].depth, notes: own))
        }
        return result
    }

    /// Workspace cards that were excerpted from this document, as outline entries of kind "摘录" (the card's text as the
    /// quote, the reader's comment as the note). `isThisDocument` decides from the card's source; cards without any
    /// source are free notes and are returned separately, since they have no page to be filed under.
    static func excerptNotes(cards: [BoardCard], isThisDocument: (SourceRef) -> Bool) -> (excerpts: [AnnotationNote], free: [AnnotationNote]) {
        var excerpts: [AnnotationNote] = [], free: [AnnotationNote] = []
        for (offset, card) in cards.enumerated() {
            let quote = card.kind == .image && card.text.isEmpty ? "（截取的页面图像）" : card.text
            if let source = card.source, isThisDocument(source) {
                excerpts.append(AnnotationNote(page: source.page, index: 1_000_000 + offset, kind: card.kind == .image ? "截图摘录" : "摘录",
                                               quote: quote, note: card.comment, label: source.pageLabel, colorName: card.color.title))
            } else if card.source == nil, card.kind == .note, !card.text.isEmpty || !card.comment.isEmpty {
                free.append(AnnotationNote(page: 0, index: 2_000_000 + offset, kind: "工作区笔记", quote: card.text, note: card.comment))
            }
        }
        return (excerpts, free)
    }

    static let freeNotesTitle = "工作区笔记（无出处）"

    private static func head(_ note: AnnotationNote) -> String { WordExport.headText(note) }

    static func markdown(title: String, sections: [NotesSection], bibliography: Bibliography? = nil) -> String {
        let clean = title.replacingOccurrences(of: "\n", with: " ")
        var text = "# \(clean) — 笔记大纲\n\n"
        if let bibliography, !bibliography.isEmpty { text += "书目：\(bibliography.citation)\n\n" }
        for section in sections {
            text += String(repeating: "#", count: min(section.depth + 2, 6)) + " " + section.title + "\n\n"
            for note in section.notes {
                text += "- **\(head(note))**\n"
                if !note.quote.isEmpty { text += note.quote.components(separatedBy: .newlines).map { "  > " + $0 }.joined(separator: "\n") + "\n" }
                if !note.note.isEmpty { text += "  笔记：" + note.note.replacingOccurrences(of: "\n", with: "\n  ") + "\n" }
                if note.quote.isEmpty && note.note.isEmpty { text += "  （图形标注，无文本）\n" }
            }
            if !section.notes.isEmpty { text += "\n" }
        }
        return text
    }

    static func plainText(title: String, sections: [NotesSection]) -> String {
        var text = "\(title) — 笔记大纲\n\n"
        for section in sections {
            text += String(repeating: "  ", count: section.depth) + section.title + "\n"
            for note in section.notes {
                let indent = String(repeating: "  ", count: section.depth + 1)
                text += indent + "[" + head(note) + "]\n"
                if !note.quote.isEmpty { text += indent + "  原文：" + note.quote.replacingOccurrences(of: "\n", with: " ") + "\n" }
                if !note.note.isEmpty { text += indent + "  笔记：" + note.note.replacingOccurrences(of: "\n", with: " ") + "\n" }
                if note.quote.isEmpty && note.note.isEmpty { text += indent + "  （图形标注，无文本）\n" }
            }
            text += "\n"
        }
        return text
    }
}

extension WordExport {
    private static func indented(_ text: String, left: Int, bold: Bool = false, gray: Bool = false, size: Int = 22) -> String {
        var run = "<w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:eastAsia=\"宋体\"/>"
        if bold { run += "<w:b/>" }
        if gray { run += "<w:color w:val=\"808080\"/>" }
        run += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
        return "<w:p><w:pPr><w:spacing w:after=\"80\" w:line=\"320\" w:lineRule=\"auto\"/><w:ind w:left=\"\(left)\"/></w:pPr><w:r><w:rPr>\(run)</w:rPr><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>"
    }

    /// A Word file of the notes outline: the sections become headings, each note a short block under them.
    static func writeNotesOutline(title: String, sections: [NotesSection], to url: URL) throws {
        let zip = try ZipWriter(url: url)
        do {
            var body = textParagraph("\(title) — 笔记大纲", style: "Heading1", size: 36, bold: true)
            for section in sections {
                body += textParagraph(section.title, style: "Heading\(min(section.depth + 2, 3))", size: 28, bold: true)
                for note in section.notes {
                    body += indented(headText(note), left: 360, bold: true, gray: true, size: 20)
                    if !note.quote.isEmpty { body += indented(note.quote.replacingOccurrences(of: "\n", with: " "), left: 720) }
                    if !note.note.isEmpty { body += indented("笔记：" + note.note.replacingOccurrences(of: "\n", with: " "), left: 720, bold: true) }
                    if note.quote.isEmpty && note.note.isEmpty { body += indented("（图形标注，无文本）", left: 720, gray: true) }
                }
            }
            let document = header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + body
                + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1417\" w:right=\"1417\" w:bottom=\"1417\" w:left=\"1417\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
            let relationships = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
            try zip.add("[Content_Types].xml", Data(contentTypes.utf8))
            try zip.add("_rels/.rels", Data(rootRelationships.utf8))
            try zip.add("word/styles.xml", Data(styles.utf8))
            try zip.add("word/document.xml", Data(document.utf8))
            try zip.add("word/_rels/document.xml.rels", Data(relationships.utf8))
            try zip.finish()
        } catch {
            zip.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func headText(_ note: AnnotationNote) -> String {
        var text = note.pageDescription + " · " + note.kind
        if ["高亮", "下划线", "删除线"].contains(note.kind), let color = note.colorName { text += "（\(color)）" }
        if !note.tags.isEmpty { text += "　" + note.tags.map { "#" + $0 }.joined(separator: " ") }
        return text
    }
}

extension Workspace {
    enum NotesOutlineFormat { case word, markdown, text }

    /// The outline as the filter and the table of contents give it, with the workspace's excerpts and free notes.
    func notesOutlineSections(filter: AnnotationFilter = AnnotationFilter()) -> [NotesSection] {
        let cards = NotesOutline.excerptNotes(cards: store?.board.cards ?? []) { [self] in matches(path: $0.path) }
        let notes = filter.apply(to: ReadingServices.notes(document) + cards.excerpts)
        let free = filter.apply(to: cards.free)
        var sections = NotesOutline.sections(notes: notes, outline: outlineEntries)
        if !free.isEmpty { sections.append(NotesSection(title: NotesOutline.freeNotesTitle, depth: 0, notes: free)) }
        return sections
    }

    func exportNotesOutline(_ format: NotesOutlineFormat, filter: AnnotationFilter = AnnotationFilter()) {
        let sections = notesOutlineSections(filter: filter)
        guard sections.contains(where: { !$0.notes.isEmpty }) else { error = "没有可导出的标注或摘录。先在页面上高亮、画线、写批注，或把文字摘录到工作区。"; return }
        writeNotesOutline(sections, format)
    }

    func writeNotesOutline(_ sections: [NotesSection], _ format: NotesOutlineFormat) {
        let total = sections.reduce(0) { $0 + $1.notes.count }
        let suffix: String, type: UTType
        switch format {
        case .word: suffix = "docx"; type = UTType(filenameExtension: "docx") ?? .data
        case .markdown: suffix = "md"; type = UTType(filenameExtension: "md") ?? .plainText
        case .text: suffix = "txt"; type = .plainText
        }
        guard let url = saveURL(type: type, suffix: suffix, name: title + "-笔记大纲") else { return }
        report {
            switch format {
            case .word: try WordExport.writeNotesOutline(title: title, sections: sections, to: url)
            case .markdown: try NotesOutline.markdown(title: title, sections: sections, bibliography: bibliography).write(to: url, atomically: true, encoding: .utf8)
            case .text: try NotesOutline.plainText(title: title, sections: sections).write(to: url, atomically: true, encoding: .utf8)
            }
            status = "已导出笔记大纲：\(total) 条（标注与摘录），\(sections.filter { !$0.notes.isEmpty }.count) 个章节"
        }
    }
}
