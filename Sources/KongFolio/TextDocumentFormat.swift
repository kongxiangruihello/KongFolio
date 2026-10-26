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
        if format == .html {
            guard let data = text.data(using: .utf8) else { throw FolioError(message: "HTML 编码失败") }
            let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            return try TextImport.pdf(from: attributed)
        }
        return try TextImport.render(text, markdown: format == .markdown)
    }
}
