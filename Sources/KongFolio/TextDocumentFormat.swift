import AppKit
import PDFKit

enum TextDocumentFormat: String, Codable, CaseIterable, Identifiable {
    case markdown = "Markdown", html = "HTML", plain = "纯文本"
    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : self == .html ? "html" : "txt" }
    static func forURL(_ url: URL) -> Self {
        let ext = url.pathExtension.lowercased()
        if TextImport.htmlExtensions.contains(ext) { return .html }
        return TextImport.markdownExtensions.contains(ext) ? .markdown : .plain
    }
}

extension MarkdownNote {
    func renderDocument() throws -> PDFDocument {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return PDFDocument() }
        let base = fileURL?.deletingLastPathComponent() ?? recoveryBaseURL
        return try RichTextDocument(try SourceLink.rebasedText(text, baseURL: base), format: format, baseURL: base, options: layoutOptions).pdf()
    }
}
