import Foundation
import PDFKit

enum BookNotebook {
    struct Snapshot {
        var title: String
        var sourcePath: String
        var sections: [NotesSection]
        var reflection: String
        var markdown: String {
            var lines = ["# " + title.replacingOccurrences(of: "\n", with: " ") + " · 阅读笔记", "", "## 我的心得", "", reflection, ""]
            for section in sections {
                lines += [String(repeating: "#", count: min(6, section.depth + 2)) + " " + section.title, ""]
                for note in section.notes {
                    lines += ["### " + WordExport.headText(note), ""]
                    if !note.quote.isEmpty { lines += note.quote.components(separatedBy: .newlines).map { "> " + $0 }; lines.append("") }
                    if !note.note.isEmpty { lines += ["我的批注：" + note.note, ""] }
                    if note.note.isEmpty && note.quote.isEmpty { lines += ["（图形或手写标注，请返回原文查看）", ""] }
                    let source = SourceRef(path: sourcePath, fileName: URL(fileURLWithPath: sourcePath).lastPathComponent, page: note.page, pageLabel: note.label, anchor: note.quote.isEmpty ? nil : note.quote)
                    if let link = SourceLink.url(source) { lines += ["[返回原文](\(link.absoluteString))", ""] }
                }
            }
            return lines.joined(separator: "\n")
        }
    }
    static func make(book: LibraryBook, pdf: Data, cards: [BoardCard], outline: [OutlineEntry]? = nil) throws -> Snapshot {
        guard let doc = PDFDocument(data: pdf), !doc.isLocked else { throw FolioError(message: "无法读取书籍的笔记，请先打开并解锁文件") }
        let path = ReadingProgress.canonicalPath(book.path)
        let excerpts = NotesOutline.excerptNotes(cards: cards) { ReadingProgress.canonicalPath($0.path) == path }.excerpts
        return Snapshot(title: book.title, sourcePath: book.path,
            sections: NotesOutline.sections(notes: ReadingServices.notes(doc) + excerpts, outline: outline ?? ReadingServices.outline(doc)), reflection: book.reflection)
    }
}
